package adam
import "../lib/alloc"
import "../lib/fs"
import "../lib/gpt"
import "../lib/ifs"
import "../lib/pci"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
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
	case .Fault:
		syscalls.syscall_debug_print_userspace("fault vector", saveArea.faultVector)
		syscalls.syscall_debug_print_userspace("fault rip", saveArea.rip)
		syscalls.syscall_debug_print_userspace("fault addr", saveArea.faultAddress)
		syscalls.grant_exit()
	case .Resume:
		unreachable()
	}
	unreachable()
}

adam_start :: proc "contextless" (pcies: []pci.Device) -> ! {
	syscalls.syscall_debug_print_userspace("adam_start", u64(uintptr(rawptr(adam_start))))
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

	for &disk, i in disks.v {
		syscalls.syscall_debug_print_userspace("disk:")
		syscalls.syscall_debug_print_userspace(fmt.tprintln(disk))
		msFs := gpt.PartitionEntry {
			firstLba   = 2048,
			lastLba    = disk.blockCount - 2048,
			attributes = {},
			name       = {},
			typeGuid   = gpt.TYPE_MS_BASIC_DATA,
			uniqueGuid = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
		}

		fses, err := fs.detect_fses(&disk, i)
		syscalls.syscall_debug_print_userspace(fmt.tprintf("detect 1 err:%d", err))
		if err != .None {

			if err == .GptNotGpt do err = fs.gpt_format(&disk, {msFs}, 128, {2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16})
			if err != nil do syscalls.syscall_debug_print_userspace(fmt.tprintf("disk err:%d", err))
			fses, err = fs.detect_fses(&disk, i)

		}
		if err != nil {
			syscalls.syscall_debug_print_userspace(fmt.tprintf("disk err:%d", err))
			syscalls.grant_exit()
		}
		if len(fses) == 0 {
			diskAlloc: ifs.DiskAllocator
			diskAlloc, err = ifs.format(&disk, msFs.firstLba, msFs.lastLba - msFs.firstLba + 1)
			syscalls.syscall_debug_print_userspace(fmt.tprintf("ifsFormatErr err:%d", err))

			fses, err = fs.detect_fses(&disk, i)
			assert(err == .None && len(fses) == 1 && fses[0].type == .Ifs)
		}
		for fileSystem in fses do syscalls.syscall_debug_print_userspace(fmt.tprintln(fileSystem))
		for fileSystem in fses {
			if fileSystem.type != .Ifs do continue
			diskAlloc, mountErr := ifs.mount(&disk, fileSystem.start, fileSystem.len)
			if mountErr != .None do syscalls.syscall_debug_print_userspace(fmt.tprintf("ifs mount err:%d", mountErr))
		}
	}
	free_all(context.temp_allocator)
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
