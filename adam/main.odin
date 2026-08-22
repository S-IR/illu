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
		config := (^pci.Header)(uintptr(device.configBase))


		command := pci.config_read_u16(&device, 0x04)
		command |= pci.COMMAND_MEMORY
		// command |= pci.COMMAND_BUS_MASTER

		pci.config_write_u16(&device, pci.CONFIG_COMMAND_OFFSET, command)

		updated := pci.config_read_u16(&device, pci.CONFIG_COMMAND_OFFSET)

		msiOffset, hasMsi := pci.find_capability(&device, pci.CAPABILITY_MSI)

		if !hasMsi do continue
		command = pci.config_read_u16(&device, 0x04)
		command |= pci.COMMAND_BUS_MASTER
		pci.config_write_u16(&device, pci.CONFIG_COMMAND_OFFSET, command)

		control := pci.config_read_u16(&device, uintptr(msiOffset) + pci.MSI_CONTROL)
		is64Bit := control & pci.MSI_CONTROL_64BIT != 0
		maskable := control & pci.MSI_CONTROL_MASK_CAPABLE != 0

		addressLow := pci.config_read_u32(&device, uintptr(msiOffset) + pci.MSI_MESSAGE_ADDR)

		addressHigh: u32 = 0
		dataOffset := pci.MSI_MESSAGE_DATA32

		if is64Bit {
			addressHigh = pci.config_read_u32(&device, uintptr(msiOffset) + uintptr(0x08))
			dataOffset = pci.MSI_MESSAGE_DATA64

		}
		messageData := pci.config_read_u16(&device, uintptr(msiOffset) + dataOffset)


	}
	// Smoke test passed.
	syscalls.syscall_exit(42)
}
