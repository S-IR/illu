package kernel
import "../lib/syscalls"
import "base:runtime"
import "print"

USER_PROCESS_DEFAULT_STACK_SIZE :: 64 * 1024

@(export)
syscall_dispatch :: proc "c" (nr, a1, a2, a3, a4, a5: u64) -> u64 {
	context = runtime.default_context()
	switch syscalls.Syscall(nr) {
	case .Exit:
		return syscall_exit(a1)
	}
	return u64(~u64(0))
}
