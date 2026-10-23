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

	metaDma := alloc.dma_pages(len(gpt.MetaBlock)) or_return
	defer syscalls.mem_free_userspace(metaDma)
	metaDmaBuf := mem.byte_slice(
		rawptr(uintptr(metaDma)),
		len(gpt.MetaBlock) * int(disk.blockSize),
	)

	arrayDma := alloc.dma_pages((arrayBytes + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE) or_return
	defer syscalls.mem_free_userspace(arrayDma)

	entriesBuf := mem.byte_slice(rawptr(uintptr(arrayDma)), int(arrayBytes))


	prpListLen := nvme.prp_list_len({entriesBuf})
	prpBuf: []u64 = nil
	prpDma: u64 = 0
	defer if prpDma != 0 do syscalls.mem_free_userspace(prpDma)
	if prpListLen > 0 {
		prpDma = alloc.dma_pages(
			u64((prpListLen + nvme.PRP_ENTRIES_PER_PAGE - 1) / nvme.PRP_ENTRIES_PER_PAGE),
		) or_return
		prpBuf = mem.slice_ptr((^u64)(uintptr(prpDma)), prpListLen)
	}

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

	SingleWrite :: struct {
		block:   u64,
		buf:     []byte,
		prpList: []u64,
	}
	writesTodo := [?]SingleWrite {
		{0, blocks[.Mbr], nil},
		{header.myLba, blocks[.PrimaryHeader], nil},
		{header.partitionEntryLba, entriesBuf, prpBuf},
		{backup.partitionEntryLba, entriesBuf, prpBuf},
		{backup.myLba, blocks[.BackupHeader], nil},
	}
	dps := make([dynamic]diskhelpers.DiskPending, 0, len(writesTodo))
	defer delete(dps)
	for writeTodo in writesTodo {
		submitErr := diskhelpers.disk_submit(
			disk,
			&dps,
			.Write,
			writeTodo.block,
			writeTodo.buf,
			writeTodo.prpList,
		)
		if submitErr != .None {
			diskhelpers.wait_all(dps[:])
			return submitErr
		}
	}
	diskhelpers.wait_all(dps[:]) or_return
	dp := diskhelpers.disk_io(disk, .Flush, 0, nil) or_return
	diskhelpers.wait(dp) or_return
	return .None
}
