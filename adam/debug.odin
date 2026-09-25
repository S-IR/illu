package adam

import "../lib/syscalls"
import "base:runtime"

// adam_assertion_failure_handler is wired into context.assertion_failure_proc
// in _start, mirroring kernel_main's print.kassert_failure_handler. It backs
// plain `assert()` calls anywhere in adam: on failure it reports the call
// site over the debug print syscall and exits.
adam_assertion_failure_handler :: proc(
	prefix, message: string,
	loc: runtime.Source_Code_Location,
) -> ! {
	syscalls.syscall_debug_print_userspace(loc.file_path, u64(loc.line))
	syscalls.grant_exit()
}
