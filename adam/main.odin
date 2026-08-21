package adam

import "../lib/acpi"
import "../lib/alloc"
import "../lib/pci"
import "../lib/syscalls"
import "base:runtime"
import "core:mem"
@(export)
_start :: proc "c" (pciesPtr: ^pci.Device, pciesLen: u64) -> ! {
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()

	err, addr := syscalls.syscall_mmap_userspace(1, ._4KB, {.Present})

	if err != .None {
		syscalls.syscall_exit(1)
	}

	if addr == nil {
		syscalls.syscall_exit(2)
	}

	myTEST := make([dynamic]u32)
	for i in 0 ..< u32(10) do append(&myTEST, i)
	delete(myTEST)

	devices := mem.slice_ptr(pciesPtr, int(pciesLen))
	sum: u32 = 0
	for &device in devices {
		sum += u32(device.bus)
		device.bus = 0
	}
	// Smoke test passed.
	syscalls.syscall_exit(42)
}
