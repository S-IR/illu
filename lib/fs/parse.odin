package fs
import "../ext4"
import "../ifs"
import "../ntfs"

import "../alloc"
import "../diskhelpers"
import "../gpt"
import "../nvme"
import "../shared"
import "../syscalls"
import "core:mem"
Fs :: struct #all_or_none {
	diskIdx: int,
	start:   u64,
	len:     u64,
	type:    FsType,
}
FsType :: enum {
	Ifs,
	Ntfs,
	Ext4,
}
detect_fses :: proc(disk: ^diskhelpers.Disk, diskIdx: int) -> (fses: [dynamic]Fs, err: shared.Error) {
	if !shared.assert(disk != nil) do return fses, .InvalidAPICall
	defer if err != .None do delete(fses)
	assert(disk.blockSize <= shared.PAGE_SIZE)
	assert(shared.PAGE_SIZE % disk.blockSize == 0)
	headerDmaBuf, hErr := make_aligned([]byte, disk.blockSize, shared.PAGE_SIZE, context.temp_allocator)
	if hErr != nil do return fses, .OutOfMemory

	dps := make([dynamic]diskhelpers.DiskPending, context.temp_allocator)
	diskhelpers.disk_io(disk, &dps, .Read, {gpt.HEADER_BLOCK_LOCATION}, {headerDmaBuf}) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)
	header := gpt.parse_header(headerDmaBuf) or_return
	if header.partitionEntryCount == 0 do return fses, .None

	bytesCount := u64(header.partitionEntryCount) * u64(header.partitionEntrySize)

	blocksCount := (bytesCount + u64(disk.blockSize) - 1) / u64(disk.blockSize)


	if blocksCount > header.firstUsableLba do return fses, .Corrupt
	if header.partitionEntryLba > header.firstUsableLba - blocksCount do return fses, .Corrupt

	entriesBuf, eErr := make_aligned(
		[]byte,
		blocksCount * u64(disk.blockSize),
		shared.PAGE_SIZE,
		context.temp_allocator,
	)
	if eErr != nil do return fses, .OutOfMemory
	diskhelpers.disk_io(disk, &dps, .Read, {header.partitionEntryLba}, {entriesBuf}) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)
	partitions := gpt.parse_entries(header, entriesBuf) or_return
	defer delete(partitions)
	if len(partitions) == 0 do return fses, .None

	partitionsBuf, dErr := make_aligned(
		[]byte,
		len(partitions) * shared.PAGE_SIZE,
		shared.PAGE_SIZE,
		context.temp_allocator,
	)
	if dErr != nil do return fses, .OutOfMemory

	partitionBlocks, bErr := make([]u64, len(partitions), context.temp_allocator)
	if bErr != nil do return fses, .OutOfMemory
	partitionBufs, pErr := make([][]byte, len(partitions), context.temp_allocator)
	if pErr != nil do return fses, .OutOfMemory
	for partition, i in partitions {
		partitionBlocks[i] = partition.firstLba
		partitionBufs[i] = partitionsBuf[i * shared.PAGE_SIZE:][:shared.PAGE_SIZE]
	}
	diskhelpers.disk_io(disk, &dps, .Read, partitionBlocks, partitionBufs) or_return
	diskhelpers.wait_all(dps[:]) or_return
	for partition, i in partitions {
		buf := partitionsBuf[i * shared.PAGE_SIZE:][:shared.PAGE_SIZE]
		fsType: FsType
		switch {
		case ntfs.is(buf):
			fsType = .Ntfs
		case ext4.is(buf):
			fsType = .Ext4
		case ifs.is(buf):
			fsType = .Ifs
		case:
			continue
		}
		fs := Fs {
			diskIdx = diskIdx,
			start   = partition.firstLba,
			len     = partition.lastLba - partition.firstLba + 1,
			type    = fsType,
		}
		if _, aErr := append(&fses, fs); aErr != nil do return fses, .OutOfMemory
	}
	return fses, .None
}
