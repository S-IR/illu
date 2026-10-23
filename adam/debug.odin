package adam
import "../lib/log"
import "../lib/syscalls"
import "base:intrinsics"
import "base:runtime"

adam_assertion_failure_handler :: proc(
	prefix, message: string,
	loc: runtime.Source_Code_Location,
) -> ! {
	log.write(&adamLog, .Critical, .None, loc = loc)
	adamLogPrinted = adam_log_dump(&adamLog, adamLogPrinted)
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
		file := string(([^]u8)(uintptr(record.file))[:record.fileLen])

		syscalls.syscall_debug_print_userspace(file, u64(record.line))
		syscalls.syscall_debug_print_userspace("severity", u64(record.severity))
		syscalls.syscall_debug_print_userspace("err", u64(record.err))
		for arg in record.args do syscalls.syscall_debug_print_userspace("arg", arg)

	}
	return head
}
