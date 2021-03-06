/*
 * File util.d
 * Fast implementation on X86_64, portable algorithm for other platform
 * of some bit functions.
 * © 2016-2019 Richard Delorme
 */

module util;
import std.array, std.conv, std.datetime, std.format, std.process, std.stdio, std.string;
import core.bitop, core.simd, core.time, core.thread, core.stdc.stdlib;

version (LDC) import ldc.intrinsics;
else version (GNU) import gcc.builtins;

/* limits */
struct Limits {
	enum ply {max = 127}
	enum game {size = 4_096}
	enum move {size = 4_096, mask = 4_095}
	enum moves {size = 256}
}

enum Score {mate = 30_000, low = -29_000, high = 29_000, big = 3_000}

enum LongFormat {off = false, on}

enum Copy {off = false, on}

enum Debug {off = false, on}

enum Loop {off = false, on}


/*
 * bit utilities
 */
/* Swap the bytes of a bitboard (vertical mirror of a Chess board) */
version (LDC) alias swapBytes = llvm_bswap;
else version(GNU) alias swapBytes = __builtin_bswap64;
else alias swapBytes = bswap;

/* Check if a single bit is set */
bool hasSingleBit(const ulong b) {
	return (b & (b - 1)) == 0;
}

/* Get the first bit set */
version (LDC) int firstBit(ulong b) {return cast (int) llvm_cttz(b, true);}
else version (GDC) alias firstBit = __builtin_ctz;
else alias firstBit = bsf;

/* Get the last bit set */
version (LDC) int lastBit(ulong b) {return cast (int) llvm_ctlz(b, true);}
version (GDC) alias lastBit = __builtin_clz;
else alias lastBit = bsr;

/* Extract a bit */
int popBit(ref ulong b) {
	const int i = firstBit(b);
	b &= b - 1;
	return i;
}

/* Count the number of bits */
version (withPopCount) {
	version (GNU) alias countBits = __builtin_popcountll;
	else version (LDC) int countBits(const ulong b) {return cast (int) llvm_ctpop(b);}
	else alias countBits = _popcnt;
} else {
	int countBits(const ulong b) {
		ulong c = b
			- ((b >> 1) & 0x7777777777777777)
			- ((b >> 2) & 0x3333333333333333)
			- ((b >> 3) & 0x1111111111111111);
		c = ((c + (c >> 4)) & 0x0F0F0F0F0F0F0F0FU) * 0x0101010101010101;

		return  cast (int) (c >> 56);
	}
}

/*
 * prefetch
 */
void prefetch(void *v) {
	version (GNU) __builtin_prefetch(v);
	else version (LDC) llvm_prefetch(v, 0, 3, 1);
	else core.simd.prefetch!(false, 3)(v);
}


/*
 * struct Chrono
 */
struct Chrono {
	private {
		TickDuration tick;
		bool on;
	}

	/* start */
	void start() {
		on = true;
		tick = TickDuration.currSystemTick();
	}

	/* stop */
	void stop() {
		on = false;
		tick = TickDuration.currSystemTick() - tick;
	}

	/* return spent time const secs with decimals */
	double time() const {
		double t;
		if (on) t = (TickDuration.currSystemTick() - tick).hnsecs;
		else t = tick.hnsecs;
		return 1e-7 * t;
	}
}

/* return milliseconds part from a (sys)time */
int millisecond(const ref SysTime t) {
	int msecs;
	t.fracSecs.split!("msecs")(msecs);
	return msecs;
}

/* return the current date */
string date() {
	SysTime t = Clock.currTime();
	return format("%d.%d.%d", t.year, t.month, t.day);
}

/* return the current hour */
string hour() {
	SysTime t = Clock.currTime();
	return format("%0d:%0d:%0d.%03d", t.hour, t.minute, t.second, t.millisecond);
}


/*
 * class Message
 * manage all io:
 *  - communication with the GUI
 *  - logging for debugging
 *  - internal message passing
 */
class Message {
private:
	string [] ring;
	size_t first, last;
	shared class Lock {};
	Lock lock, ioLock;
	string header;
	File logFile;

public:
	/* ring is empty */
	bool empty() const @property {
		return first == last;
	}

	/* ring is full */
	bool full() const @property {
		return first == (last + 1)  % ring.length;
	}

	/* constructor */
	this (string h = "") {
		ring.length = 4;
		lock = new Lock;
		ioLock = new Lock;
		header = h;
	}

	/* clear */
	void clear() {
		first = last = 0;
	}

	/* push a new event to the ring */
	void push(string s) {
		synchronized (lock) {
			if (full) {
				const l = ring.length, δ = l - 1;
				ring.length = 2 * l;
				foreach (i ; 0 .. first) ring[i + δ] = ring[i];
				last = first + δ;
			}
			ring[last] = s;
			last = (last + 1) % ring.length;
		}
	}

	/* peek an event */
	string peek() {
		string s;
		synchronized (lock) {
			if (!empty) {
				s = ring[first];
				ring[first] = null;
				first = (first  + 1) % ring.length;
			}
		}
		if (s !is null) log!'<'(s);
		return s;
	}

	/* wait for an event */
	string retrieve() {
		while (empty) Thread.sleep(1.msecs);
		return peek();
	}

	/* has event s */
	bool has(string s) {
		return !empty && ring[first] == s;
	}

	/* loop */
	void loop() {
		string line;
		do {
			line = readln().chomp();
			push(line);
		} while (line != "quit" && stdin.isOpen);
		log("Bye!");
	}

	/* daemon */
	void daemon() {
		auto t = new Thread((){loop();});
		t.isDaemon = true;
		t.start();
	}

	/* send */
	void send(T...) (T args) {
		stdout.writeln(args);
		stdout.flush();
		log!'>'(args);
	}

	/* log */
	void log(const char tag = '#', T...) (T args) {
		synchronized (ioLock) {
			if (logFile.isOpen) {
				logFile.writef("[%s %s] %s%c ", date(), hour(), header, tag);
				logFile.writeln(args);
				logFile.flush();
			}
		}
	}

	void write(const char tag = '#', T...) (T args) {
		synchronized (ioLock) {
			if (logFile.isOpen) {
				logFile.write(args);
			}
		}
	}

	/* turn on logging for debugging purpose */
	void logOn() {
		if (!logFile.isOpen) logFile.open(header ~ "-" ~ to!string(thisProcessID) ~ ".log", "w");
	}

	/* turn off logging for debugging purpose */
	void logOff() {
		if (logFile.isOpen) logFile.close();
	}

	/* tell if logging is on */
	bool isLogging() {
		return logFile.isOpen;
	}
}


/*
 * Miscellaneous utilities
 */

/* a replacement for assert that is more practical for debugging */
void claim(bool allegation, string file = __FILE__, const int line = __LINE__, const string msg = ": Assertion failed.") {
	if (!allegation) {
		stderr.writeln(file, ":", line, msg);
		abort();
	}
}

/* unreachable */
void unreachable(string file = __FILE__, const int line = __LINE__) {
	claim(0, file, line, "Unreachable code");
}

/* find a substring between two strings */
string findBetween(string s, string start, string end) {
	size_t i, j;

	for (; i < s.length; ++i) if (s[i .. i + start.length] == start) break;
	i += start.length; if (i > s.length) i = s.length;
	for (j = i; j < s.length; ++j) if (s[j .. j + end.length] == end) break;

	return s[i .. j];
}

/* check if a File is writeable/readable */
bool isOK(const std.stdio.File f) @property {
	return f.isOpen && !f.eof && !f.error;
}

