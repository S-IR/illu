package adam
import "../lib/alloc"
import "../lib/pci"
import "../lib/syscalls"
import "base:runtime"
import "core:mem"
@(export)
_start :: proc "c" (pciesPtr: ^pci.Device, pciesLen: u64) -> ! {
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()


	devices := mem.slice_ptr(pciesPtr, int(pciesLen))

	for &device in devices {
		result, code := adam_dispatch_pci_device(&device)
		if result == .Failed do syscalls.syscall_exit(code)
	}
	if wifi_count() == 0 do syscalls.syscall_exit(120)

	// PCI scan and all currently registered drivers completed.
	syscalls.syscall_exit(42)
}
