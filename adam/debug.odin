package adam
import "../lib/log"
import "../lib/syscalls"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
adam_assertion_failure_handler :: proc(
	prefix, message: string,
	loc: runtime.Source_Code_Location,
) -> ! {
	sep := ": " if len(message) > 0 else ""
	lineBuf: [512]u8
	syscalls.syscall_debug_print_userspace(
		fmt.bprintf(
			lineBuf[:],
			"%s(%d:%d) %s%s%s",
			loc.file_path,
			loc.line,
			loc.column,
			prefix,
			sep,
			message,
		),
	)
	syscalls.grant_exit()
}
adam_log_dump :: proc "contextless" (ring: ^log.Ring, from: u64) -> u64 {
	head := intrinsics.atomic_load(&ring.head)
	n := u64(len(ring.records))
	start := max(from, head - n if head > n else 0)

	for index in start ..< head {
		slot := &ring.records[index & (n - 1)]
		seq := intrinsics.atomic_load_explicit(&slot.seq, .Acquire)
		if seq != u8(index % 255 + 1) do continue
		record := slot^
		intrinsics.atomic_thread_fence(.Acquire)
		seq2 := intrinsics.atomic_load_explicit(&slot.seq, .Acquire)
		if seq != seq2 do continue
		context = runtime.default_context()
		file := string(([^]u8)(uintptr(record.file))[:record.fileLen])
		file = file[strings.last_index_byte(file, '/') + 1:]
		lineBuf: [256]u8
		text := fmt.bprintf(
			lineBuf[:],
			"%s:%d %v %v %v",
			file,
			record.line,
			record.severity,
			record.err,
			record.args,
		)
		syscalls.syscall_debug_print_userspace(text)

	}
	return head
}
