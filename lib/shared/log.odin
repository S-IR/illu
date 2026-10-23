package shared

Severity :: enum u8 {
	Emergency,
	Alert,
	Critical,
	Error,
	Warning,
	Notice,
	Informational,
	Debug,
}

LogRecord :: struct {
	tsc:      u64,
	err:      Error,
	file:     u64,
	fileLen:  u16,
	severity: Severity,
	_:        byte,
	line:     u32,
	args:     [4]u64,
}
#assert(size_of(LogRecord) == 64)
