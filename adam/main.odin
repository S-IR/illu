package adam
import "../lib/alloc"
import "../lib/lmem"
import "../lib/pe"
import "../lib/pci"
import "../lib/syscalls"
import "base:runtime"
import "core:mem"
FIRSTPE_BYTES := #load("../firstpe/firstpe.exe", []u8)

NTD_IMMITATOR_BYTE := #load("../diskimg/ntdll_immitator.dll")

@(export)
_start :: proc "c" (pciesPtr: ^pci.Device, pciesLen: u64) -> ! {
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()
	context.temp_allocator = alloc.heap_allocator()
	context.assertion_failure_proc = adam_assertion_failure_handler

	_, ntdiOk := pe.register("ntdll.dll", NTD_IMMITATOR_BYTE)
	if !ntdiOk do syscalls.syscall_exit(1000)

	fpBc, fpOk := pe.load(FIRSTPE_BYTES)
	if !fpOk do syscalls.syscall_exit(1100)

	if runErr := pe.pe_run(&fpBc, fpBc.image.entryRva, 0, 0); runErr != .None do syscalls.syscall_exit(1200)

	// txErr, tx := syscalls.syscall_mmap_userspace(2, lmem.PageSize._4KB, {.Present, .Write})
	// if txErr != .None || tx == nil do syscalls.syscall_exit(130)
	// rxErr, rx := syscalls.syscall_mmap_userspace(7, lmem.PageSize._4KB, {.Present, .Write})
	// if rxErr != .None || rx == nil do syscalls.syscall_exit(131)
	// dma := WifiDma{tx = tx, txPhys = u64(uintptr(tx)), rx = rx, rxPhys = u64(uintptr(rx))}

	// devices := mem.slice_ptr(pciesPtr, int(pciesLen))

	// for &device in devices {
	// 	result, code := adam_dispatch_pci_device(&device)
	// 	if result == .Failed do syscalls.syscall_exit(code)
	// }
	// for &device in networkRegistry.wifis {
	// 	if !wifi_configure_io(&device, dma) do syscalls.syscall_exit(132)
	// }
	// if networkRegistry.wifis == nil do syscalls.syscall_exit(12353213)
	// if len(networkRegistry.wifis) == 0 do syscalls.syscall_exit(120)
	// testFrame: [24]u8
	// testFrame[0] = 0x08
	// testFrame[1] = 0x00
	// for i in 4 ..< 22 { testFrame[i] = 0xFF }
	// if wifi_send(&networkRegistry.wifis[0], testFrame[:]) != .None do syscalls.syscall_exit(133)

	// PCI scan and all currently registered drivers completed.
	syscalls.syscall_exit(42)
}
