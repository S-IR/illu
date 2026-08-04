package kernel
import "../lib/syscalls"
import "base:runtime"
import "print"

@(export)
syscall_dispatch :: proc "c" (nr, a1, a2, a3, a4, a5: u64) -> u64 {
	switch syscalls.Syscall(nr) {
	case .Exit:
		print.serial_write("exit code: ")
		print.serial_write_u64(a1)
		print.serial_writeln("")
		exec_exit_current() // does not return
	}
	return u64(~u64(0))
}
