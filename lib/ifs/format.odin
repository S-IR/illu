package ifs
import "../alloc"
import "../diskhelpers"
import "../shared"
import "../syscalls"
import "base:intrinsics"
import "core:mem"
format :: proc(
	disk: ^diskhelpers.Disk,
	partStart, partBlocks: u64,
) -> (
	diskAlloc: DiskAllocator,
	err: shared.Error,
) {
	if !shared.assert(disk != nil) do return diskAlloc, .InvalidAPICall
	if !shared.assert(shared.PAGE_SIZE % disk.blockSize == 0) do return diskAlloc, .InvalidAPICall
	if !shared.assert(partBlocks > 1) do return diskAlloc, .InvalidAPICall
	partUpperBound, overflown := intrinsics.overflow_add(partStart, partBlocks)
	if !shared.assert(!overflown) do return diskAlloc, .InvalidAPICall
	if !shared.assert(partUpperBound <= disk.blockCount) do return diskAlloc, .InvalidAPICall

	diskAlloc = disk_allocator_init({1, partBlocks - 1}, nil) or_return
	defer if err != .None do delete(diskAlloc.free)


	dirBlock := disk_alloc(&diskAlloc, ROOT_DIR_DEFAULT_CAP / u64(disk.blockSize)) or_return
	nameBlock := disk_alloc(&diskAlloc, NAME_FILE_DEFAULT_CAP / u64(disk.blockSize)) or_return

	pages, aErr := make_aligned([]byte, 3 * shared.PAGE_SIZE, shared.PAGE_SIZE, context.temp_allocator)
	if aErr != nil do return diskAlloc, .OutOfMemory

	sb: Superblock = {
		magic = IFS_MAGIC,
		root  = {dirBlock * u64(disk.blockSize), ROOT_DIR_DEFAULT_CAP},
	}
	rootDir := DirHeader{1, 0}
	rootNameSlot := Slot{nameBlock * u64(disk.blockSize), NAME_FILE_DEFAULT_CAP}

	sbBuf := pages[:disk.blockSize]
	dirBuf := pages[shared.PAGE_SIZE:][:ROOT_DIR_DEFAULT_CAP]
	nameBuf := pages[2 * shared.PAGE_SIZE:][:NAME_FILE_DEFAULT_CAP]

	copy(sbBuf, mem.any_to_bytes(sb))
	copy(dirBuf, mem.any_to_bytes(rootDir))
	copy(dirBuf[size_of(DirHeader):], mem.any_to_bytes(rootNameSlot))
	copy(nameBuf, mem.any_to_bytes(NameFileHeader{0, NAME_FILE_DEFAULT_CAP}))

	dps := make([dynamic]diskhelpers.DiskPending, 0, 2)
	defer delete(dps)
	diskhelpers.disk_io(
		disk,
		&dps,
		.Write,
		{partStart + dirBlock, partStart + nameBlock},
		{dirBuf, nameBuf},
	) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)

	diskhelpers.disk_io(disk, &dps, .Flush, nil, nil) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)

	diskhelpers.disk_io(disk, &dps, .Write, {partStart}, {sbBuf}) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)

	diskhelpers.disk_io(disk, &dps, .Flush, nil, nil) or_return
	diskhelpers.wait_all(dps[:]) or_return
	return diskAlloc, .None
}
