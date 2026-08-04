package syscalls

Syscall :: enum {
	Exit,
}

foreign _ {
	syscall_exit :: proc(code: u64) -> ! ---
}
