package kernel

@(export)
syscall_dispatch :: proc "c" (nr, a1, a2, a3, a4, a5: u64) -> u64 {
	// Minimal stub: we'll implement real syscalls later
	_ = nr; _ = a1; _ = a2; _ = a3; _ = a4; _ = a5
	return 0
}
