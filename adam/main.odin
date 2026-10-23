package adam
import "../lib/alloc"
import "../lib/fs"
import "../lib/gpt"
import "../lib/ifs"
import "../lib/log"
import "../lib/pci"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "base:runtime"
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
		log.write(
			&adamLog,
			.Critical,
			.None,
			saveArea.faultVector,
			saveArea.rip,
			saveArea.faultAddress,
			saveArea.faultError,
		)
		adamLogPrinted = adam_log_dump(&adamLog, adamLogPrinted)
		syscalls.grant_exit()
	case .Resume:
		unreachable()
	}
	unreachable()
}

adam_start :: proc "contextless" (pcies: []pci.Device) -> ! {
	adamLog.records = adamLogRecords[:]
	log.write(&adamLog, .Debug, .None, u64(uintptr(rawptr(adam_start))))
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()
	context.temp_allocator = alloc.heap_allocator()
	context.assertion_failure_proc = adam_assertion_failure_handler

	for &device in pcies {
		result, code := adam_dispatch_pci_device(&device)

		switch result {
		case .Initialized:
			log.write(&adamLog, .Notice, .None, u64(device.classCode))
		case .Failed:
			log.write(&adamLog, .Error, code, u64(device.classCode))
		case .Ignored, .Unsupported:
		}
	}

	for &disk, i in disks.v {
		log.write(&adamLog, .Informational, .None, u64(i), disk.blockCount, u64(disk.blockSize))
		msFs := gpt.PartitionEntry {
			firstLba   = 2048,
			lastLba    = disk.blockCount - 2048,
			attributes = {},
			name       = {},
			typeGuid   = gpt.TYPE_MS_BASIC_DATA,
			uniqueGuid = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
		}

		fses, err := fs.detect_fses(&disk, i)
		log.write(&adamLog, .Informational, err, u64(i))
		if err != .None {

			if err == .GptNotGpt do err = fs.gpt_format(&disk, {msFs}, 128, {2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16})
			if err != .None do log.write(&adamLog, .Error, err, u64(i))
			fses, err = fs.detect_fses(&disk, i)

		}
		if err != .None {
			log.write(&adamLog, .Error, err, u64(i))
			adamLogPrinted = adam_log_dump(&adamLog, adamLogPrinted)
			syscalls.grant_exit()
		}
		if len(fses) == 0 {
			diskAlloc: ifs.DiskAllocator
			diskAlloc, err = ifs.format(&disk, msFs.firstLba, msFs.lastLba - msFs.firstLba + 1)
			if err != .None do log.write(&adamLog, .Error, err, u64(i), msFs.firstLba)

			fses, err = fs.detect_fses(&disk, i)
			assert(err == .None && len(fses) == 1 && fses[0].type == .Ifs)
		}
		for fileSystem in fses {
			log.write(
				&adamLog,
				.Notice,
				.None,
				u64(fileSystem.diskIdx),
				fileSystem.start,
				fileSystem.len,
				u64(fileSystem.type),
			)
		}
		for fileSystem in fses {
			if fileSystem.type != .Ifs do continue
			diskAlloc, mountErr := ifs.mount(&disk, fileSystem.start, fileSystem.len)
			if mountErr != .None {
				log.write(&adamLog, .Error, mountErr, fileSystem.start, fileSystem.len)
			} else {
				log.write(&adamLog, .Notice, .None, fileSystem.start, fileSystem.len)
			}
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
