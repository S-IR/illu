package adam

import "../lib/syscalls"
import "base:runtime"

// adam_assertion_failure_handler is wired into context.assertion_failure_proc
// in _start, mirroring kernel_main's print.kassert_failure_handler. It backs
// plain `assert()` calls anywhere in adam: on failure it reports the call
// site over the debug-only syscall (compiled out entirely in non -debug
// builds, same as the kernel's serial log there) and exits -- adam has no
// other way to surface a message, so failing loudly and stopping is the
// correct behavior in both build modes.
adam_assertion_failure_handler :: proc(
	prefix, message: string,
	loc: runtime.Source_Code_Location,
) -> ! {
	when ODIN_DEBUG {
		syscalls.syscall_debug_print_userspace(loc.file_path, u64(loc.line))
	}
	syscalls.syscall_exit(255)
}
