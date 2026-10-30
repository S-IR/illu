package adam
import "../lib/alloc"
import "../lib/diskhelpers"
import "../lib/fs"
import "../lib/gpt"
import "../lib/ifs"
import "../lib/log"
import "../lib/pci"
import "../lib/shared"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
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

adamHeap: alloc.Heap

adam_start :: proc "contextless" (pcies: []pci.Device) -> ! {
	adamLog.records = adamLogRecords[:]
	log.write(&adamLog, .Debug, .None, u64(uintptr(rawptr(adam_start))))
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator(&adamHeap)
	tempArena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&tempArena, alloc.heap_allocator(&adamHeap), alloc.heap_allocator(&adamHeap))

	context.temp_allocator = mem.dynamic_arena_allocator(&tempArena)
	context.assertion_failure_proc = adam_assertion_failure_handler

	ring_test()

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

	if len(disks.v) > 0 do ring_nvme_test(&disks.v[0])

	ifsPathmap := make(ifs.Pathmap)

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
			diskAlloc, root, mountErr := ifs.mount(&disk, fileSystem.start, fileSystem.len)
			if mountErr != .None {
				log.write(&adamLog, .Error, mountErr, fileSystem.start, fileSystem.len)

			} else {
				log.write(&adamLog, .Notice, .None, fileSystem.start, fileSystem.len)
				if map_insert(&ifsPathmap, ifs.path_key("/"), ifs.PathEntry{root, 0}) == nil {
					syscalls.syscall_debug_print_userspace("alloc err for path insert ")
				}
				testErr := ifs_test(&disk, fileSystem.start, fileSystem.len, &diskAlloc, root)
				if testErr == .None {
					log.write(&adamLog, .Notice, testErr, fileSystem.start)
				} else {
					log.write(&adamLog, .Error, testErr, fileSystem.start)
				}


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
ifs_test :: proc(
	disk: ^diskhelpers.Disk,
	partStart, partBlocks: u64,
	diskAlloc: ^ifs.DiskAllocator,
	root: ifs.Slot,
) -> (
	err: shared.Error,
) {
	blockSize := u64(disk.blockSize)
	dps := make([dynamic]diskhelpers.DiskPending, context.temp_allocator)

	dirBufs, nameBufs := ifs.dirs_read(disk, partStart, partBlocks, {root}) or_return
	dirBuf, nameBuf := dirBufs[0], nameBufs[0]
	assert(nameBuf != nil)
	_, slots := ifs.dir_parse(dirBuf) or_return
	nameSlot := slots[0]

	block := ifs.disk_alloc(diskAlloc, shared.PAGE_SIZE / blockSize) or_return
	file := ifs.Slot{block * blockSize, shared.PAGE_SIZE}
	fileIdx := ifs.dir_slot_set(dirBuf, file) or_return
	ifs.name_insert(nameBuf, fileIdx, "hello.txt") or_return

	data, aErr := make_aligned([]byte, shared.PAGE_SIZE, shared.PAGE_SIZE, context.temp_allocator)
	if aErr != nil do return .OutOfMemory
	for &b, i in data do b = u8(i)


	ifs.files_io(
		disk,
		partStart,
		.Write,
		{file, root, nameSlot},
		{0, 0, 0},
		{data, dirBuf, nameBuf},
		false,
		&dps,
	) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)

	back := ifs.slots_read(disk, partStart, {file}, &dps) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)
	assert(slice.equal(back[0], data))

	pathmap := make(ifs.Pathmap, context.temp_allocator)
	if map_insert(&pathmap, ifs.path_key("/"), ifs.PathEntry{root, 0}) == nil do return .OutOfMemory
	entry := ifs.path_lookup(&pathmap, disk, partStart, partBlocks, "/hello.txt") or_return
	assert(entry.slot == file && entry.slotIdx == fileIdx)

	removedIdx := ifs.name_remove(nameBuf, "hello.txt") or_return
	assert(removedIdx == fileIdx)
	ifs.dir_slot_clear(dirBuf, fileIdx) or_return
	ifs.files_io(
		disk,
		partStart,
		.Write,
		{root, nameSlot},
		{0, 0},
		{dirBuf, nameBuf},
		false,
		&dps,
	) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)
	ifs.disk_free(diskAlloc, block, file.cap / blockSize) or_return

	return .None

}
