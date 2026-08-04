package adam

import "../lib/syscalls"
@(export)
_start :: proc "c" () -> ! {
	syscalls.syscall_exit(42)
}
