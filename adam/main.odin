package adam

import "../lib/acpi"
import "../lib/syscalls"
@(export)
_start :: proc "c" (rsdp: ^acpi.Rsdp) -> ! {

	err, addr := syscalls.syscall_mmap_userspace(1, ._4KB, {.Present})

	if err != .None {
		syscalls.syscall_exit(1)
	}

	if addr == nil {
		syscalls.syscall_exit(2)
	}

	// Smoke test passed.
	syscalls.syscall_exit(42)
}
