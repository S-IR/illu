package fs
import "../ext4"
import "../ifs"
import "../ntfs"

import "../alloc"
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
detect_fses :: proc(disk: ^Disk, diskIdx: int) -> (fses: [dynamic]Fs, err: shared.Error) {
	if !shared.api_check(disk != nil) do return fses, .InvalidAPICall
	assert(disk.blockSize <= shared.PAGE_SIZE)
	assert(shared.PAGE_SIZE % disk.blockSize == 0)
	headerDma, k := alloc.dma_pages(1)
	if !k do return nil, .OutOfMemory
	defer syscalls.mem_free_userspace(headerDma)
	headerDmaBuf := mem.byte_slice(rawptr(uintptr(headerDma)), int(disk.blockSize))


	dp := read_from_disk(disk, gpt.HEADER_BLOCK_LOCATION, headerDmaBuf) or_return
	wait(dp) or_return
	header := gpt.parse_header(headerDmaBuf) or_return
	if header.partitionEntryCount == 0 do return fses, .None

	bytesCount := u64(header.partitionEntryCount) * u64(header.partitionEntrySize)

	blocksCount := (bytesCount + u64(disk.blockSize) - 1) / u64(disk.blockSize)


	if blocksCount > header.firstUsableLba do return fses, .Corrupt
	if header.partitionEntryLba > header.firstUsableLba - blocksCount do return fses, .Corrupt

	entriesDma, k2 := alloc.dma_pages(
		(blocksCount * u64(disk.blockSize) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE,
	)
	if !k2 do return fses, .OutOfMemory
	defer syscalls.mem_free_userspace(entriesDma)

	entriesBuf := mem.byte_slice(
		rawptr(uintptr(entriesDma)),
		int(blocksCount * u64(disk.blockSize)),
	)
	prpListLen := nvme.prp_list_len({entriesBuf})
	prpBuf: []u64 = nil
	prpDma: u64 = 0
	defer if prpDma != 0 do syscalls.mem_free_userspace(prpDma)
	if prpListLen > 0 {
		prpK: bool
		prpDma, prpK = alloc.dma_pages(
			u64((prpListLen + nvme.PRP_ENTRIES_PER_PAGE - 1) / nvme.PRP_ENTRIES_PER_PAGE),
		)
		if !prpK do return {}, .OutOfMemory
		prpBuf = mem.slice_ptr((^u64)(uintptr(prpDma)), prpListLen)
	}
	dp = read_from_disk(disk, header.partitionEntryLba, entriesBuf, prpBuf) or_return
	wait(dp) or_return
	partitions := gpt.parse_entries(header, entriesBuf) or_return
	defer delete(partitions)
	if len(partitions) == 0 do return fses, .None

	partitionDmas, okPartitions := alloc.dma_pages(u64(len(partitions)))
	if !okPartitions do return {}, .OutOfMemory
	defer syscalls.mem_free_userspace(partitionDmas)
	partitionsBuf := mem.byte_slice(
		rawptr(uintptr(partitionDmas)),
		len(partitions) * shared.PAGE_SIZE,
	)

	dps := make([dynamic]DiskPending, 0, len(partitions))
	defer delete(dps)
	for partition, i in partitions {
		buf := partitionsBuf[i * shared.PAGE_SIZE:][:shared.PAGE_SIZE]
		for {
			partDp, readErr := read_from_disk(disk, partition.firstLba, buf)
			if readErr == .None {
				append(&dps, partDp)
				break
			}
			if readErr == .NvmeQueueFull && len(dps) > 0 {
				wait_all(&dps) or_return
				continue
			}
			wait_all(&dps)
			return fses, readErr
		}
	}
	wait_all(&dps) or_return
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
		append(
			&fses,
			Fs {
				diskIdx = diskIdx,
				start = partition.firstLba,
				len = partition.lastLba - partition.firstLba + 1,
				type = fsType,
			},
		)
	}
	return fses, .None
}
DiskPending :: union {
	nvme.Pending,
}

read_from_disk :: proc(
	disk: ^Disk,
	block: u64,
	buffer: []byte,
	prpList: []u64 = nil,
) -> (
	dp: DiskPending,
	err: shared.Error,
) {
	if !shared.api_check(disk != nil) do return {}, .InvalidAPICall
	if !shared.api_check(len(buffer) != 0) do return {}, .InvalidAPICall


	switch &d in disk.driver {
	case NvmeDisk:
		if !shared.api_check(len(buffer) % int(d.dev.lbaSize) == 0) do return {}, .InvalidAPICall

		blockCount := len(buffer) / int(d.dev.lbaSize)
		if !shared.api_check(block <= disk.blockCount) do return {}, .InvalidAPICall
		if !shared.api_check(u64(blockCount) <= disk.blockCount - block) do return {}, .InvalidAPICall
		return nvme.queue_io(&d.queue, .Read, block, {buffer}, prpList)

	// d is NvmeDisk, bound by reference
	}
	unreachable()
}
wait :: proc(dp: DiskPending) -> shared.Error {
	switch p in dp {
	case nvme.Pending:
		return nvme.wait(p, max(u64))
	}
	unreachable()
}
wait_all :: proc(dps: ^[dynamic]DiskPending) -> (err: shared.Error) {
	for dp in dps^ {
		waitErr := wait(dp)
		if err == .None do err = waitErr
	}
	clear(dps)
	return err
}
