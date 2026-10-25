package fs

import "../alloc"
import "../diskhelpers"
import "../gpt"
import "../nvme"
import "../shared"
import "../syscalls"
import "core:hash"
import "core:mem"

gpt_format :: proc(
	disk: ^diskhelpers.Disk,
	entries: []gpt.PartitionEntry,
	entryCount: u32,
	diskGuid: gpt.Guid,
) -> (
	err: shared.Error,
) {

	if !shared.assert(disk != nil) do return .InvalidAPICall
	if !shared.assert(disk.blockSize <= shared.PAGE_SIZE) do return .InvalidAPICall
	if !shared.assert(shared.PAGE_SIZE % disk.blockSize == 0) do return .InvalidAPICall

	header := gpt.header_new(disk.blockCount, disk.blockSize, entryCount, diskGuid) or_return
	arrayBlocks := header.firstUsableLba - header.partitionEntryLba
	arrayBytes := arrayBlocks * u64(disk.blockSize)

	metaDmaBuf, mErr := make_aligned(
		[]byte,
		len(gpt.MetaBlock) * int(disk.blockSize),
		shared.PAGE_SIZE,
		context.temp_allocator,
	)
	if mErr != nil do return .OutOfMemory
	entriesBuf, eErr := make_aligned([]byte, arrayBytes, shared.PAGE_SIZE, context.temp_allocator)
	if eErr != nil do return .OutOfMemory


	blocks: [gpt.MetaBlock][]byte
	for &block, i in blocks {
		block = metaDmaBuf[int(i) * int(disk.blockSize):][:int(disk.blockSize)]
	}
	mbr := gpt.protective_mbr(disk.blockCount) or_return
	copy(blocks[.Mbr], mem.any_to_bytes(mbr))

	header.partitionEntryArrayCrc32 = gpt.entries_write(header, entries, entriesBuf) or_return
	header.headerCrc32 = hash.crc32(mem.any_to_bytes(header))
	copy(blocks[.PrimaryHeader], mem.any_to_bytes(header))

	backup := header
	backup.myLba, backup.alternateLba = backup.alternateLba, backup.myLba
	backup.partitionEntryLba = header.lastUsableLba + 1
	backup.headerCrc32 = 0
	backup.headerCrc32 = hash.crc32(mem.any_to_bytes(backup))
	copy(blocks[.BackupHeader], mem.any_to_bytes(backup))
	assert(backup.partitionEntryLba + arrayBlocks == backup.myLba)

	dps := make([dynamic]diskhelpers.DiskPending, context.temp_allocator)
	diskhelpers.disk_io(
		disk,
		&dps,
		.Write,
		{0, header.myLba, header.partitionEntryLba, backup.partitionEntryLba, backup.myLba},
		{blocks[.Mbr], blocks[.PrimaryHeader], entriesBuf, entriesBuf, blocks[.BackupHeader]},
	) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)

	diskhelpers.disk_io(disk, &dps, .Flush, nil, nil) or_return
	diskhelpers.wait_all(dps[:]) or_return
	return .None
}
