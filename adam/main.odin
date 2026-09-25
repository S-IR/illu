package adam
import "../lib/alloc"
import "../lib/lmem"
import "../lib/pci"
import "../lib/pe"
import "../lib/syscalls"
import "base:runtime"
import "core:mem"
FIRSTPE_BYTES := #load("../firstpe/firstpe.exe", []u8)

NTD_IMMITATOR_BYTE := #load("../diskimg/ntdll_immitator.dll")

@(export)
_start :: proc "c" (
	reason: syscalls.SchedulerEnterReason,
	pciesPtr: ^pci.Device,
	pciesLen: u64,
	saveArea: ^syscalls.UserSaveArea,
) -> ! {
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()
	context.temp_allocator = alloc.heap_allocator()
	context.assertion_failure_proc = adam_assertion_failure_handler

	switch reason {
	case .Start:
		adam_start(pciesPtr, pciesLen)
	case .Fault:
		syscalls.syscall_exit(1)
	}
	unreachable()
}

adam_start :: proc(pciesPtr: ^pci.Device, pciesLen: u64) -> ! {
	_ = pciesPtr
	_ = pciesLen
	counter: u64
	for {
		when ODIN_DEBUG {
			syscalls.syscall_debug_print_userspace("adam alive", counter)
		}
		counter += 1
	}
}
