package log
import "../shared"
import "../syscalls"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"

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

Record :: struct {
	tsc:      u64,
	err:      shared.Error,
	file:     u64,
	fileLen:  u16,
	severity: Severity,
	seq:      u8,
	line:     u32,
	args:     [4]u64,
}
#assert(size_of(Record) == 64)

Ring :: struct {
	head:    u64,
	records: []Record,
}
ring_push :: proc "contextless" (ring: ^Ring, record: Record) {
	assert_contextless(math.is_power_of_two(len(ring.records)))
	index := intrinsics.atomic_add(&ring.head, 1)
	slot := &ring.records[index & u64(len(ring.records) - 1)]
	intrinsics.atomic_store_explicit(&slot.seq, 0, .Relaxed)
	intrinsics.atomic_thread_fence(.Release)

	localRecord := record
	localRecord.seq = 0
	slot^ = localRecord
	intrinsics.atomic_store_explicit(&slot.seq, u8(index % 255 + 1), .Release)
}
LOG_MAX_SEVERITY :: Severity.Debug when ODIN_DEBUG else Severity.Notice

write :: proc "contextless" (
	ring: ^Ring,
	$severity: Severity,
	err: shared.Error,
	args: ..u64,
	loc := #caller_location,
) {
	when severity > LOG_MAX_SEVERITY do return


	assert_contextless(len(loc.file_path) <= int(max(u16)))
	record := Record {
		tsc      = u64(intrinsics.read_cycle_counter()),
		err      = err,
		severity = severity,
		file     = u64(uintptr(raw_data(loc.file_path))),
		fileLen  = u16(len(loc.file_path)),
		line     = u32(loc.line),
	}
	assert_contextless(len(args) <= len(record.args))
	copy(record.args[:], args)
	ring_push(ring, record)
	// when ODIN_DEBUG {
	// 	context = runtime.default_context()
	// 	file := loc.file_path[strings.last_index_byte(loc.file_path, '/') + 1:]
	// 	lineBuf: [256]u8
	// 	syscalls.syscall_debug_print_userspace(
	// 		fmt.bprintf(lineBuf[:], "%s:%d %v %v %v", file, loc.line, severity, err, record.args),
	// 	)
	// }
}
