package adam
import "../lib/alloc"
import "../lib/pci"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:runtime"
import "core:fmt"
import "core:slice"
ALIVE_PRINT_MASK :: u64(1) << 24 - 1

@(export)
adam_entry :: proc "c" (
	reason: syscalls.SchedulerEnterReason,
	pciesPtr: ^pci.Device,
	pciesLen: u64,
	saveArea: ^userschedule.UserSaveArea,
) -> ! {

	switch reason {
	case .Start:
		adam_start(slice.from_ptr(pciesPtr, int(pciesLen)))
	case .Fault, .Resume:
		syscalls.grant_exit()
	}
	unreachable()
}

adam_start :: proc "contextless" (pcies: []pci.Device) -> ! {
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()
	context.temp_allocator = alloc.heap_allocator()
	context.assertion_failure_proc = adam_assertion_failure_handler

	context.logger = runtime.Logger {
		procedure    = adam_logger_proc,
		data         = nil,
		lowest_level = .Debug,
		options      = {.Level, .Short_File_Path},
	}

	for &device in pcies {
		result, code := adam_dispatch_pci_device(&device)

		switch result {
		case .Initialized:
			syscalls.syscall_debug_print_userspace(
				"pci driver initialized, class",
				u64(device.classCode),
			)
		case .Failed:
			syscalls.syscall_debug_print_userspace("pci driver failed")
			syscalls.syscall_debug_print_userspace(fmt.tprint(code))
		case .Ignored, .Unsupported:
		// syscalls.syscall_debug_print_userspace("pci driver ignored or unsupported", code)

		}
	}

	for disk in disks.v {
		syscalls.syscall_debug_print_userspace("disk:")
		syscalls.syscall_debug_print_userspace(fmt.tprintln(disk))
	}
	alive_loop()
}

alive_loop :: proc "c" () -> ! {
	counter: u64
	for {
		if counter & ALIVE_PRINT_MASK == 0 {
			syscalls.syscall_debug_print_userspace(
				"alive on cpu",
				u64(syscalls.cpu_current_index()),
			)
		}
		counter += 1
	}
}
adam_logger_proc :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	syscalls.syscall_debug_print_userspace(text)
}
