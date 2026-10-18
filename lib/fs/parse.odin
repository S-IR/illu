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
	assert(disk.blockSize <= shared.PAGE_SIZE)
	assert(shared.PAGE_SIZE % disk.blockSize == 0)
	headerDma, k := alloc.dma_pages(1)
	if !k do return nil, .OutOfMemory
	defer syscalls.mem_free_userspace(headerDma)
	headerDmaBuf := mem.byte_slice(rawptr(uintptr(headerDma)), int(disk.blockSize))


	dp := diskhelpers.disk_io(disk, .Read, gpt.HEADER_BLOCK_LOCATION, headerDmaBuf) or_return
	diskhelpers.wait(dp) or_return
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
	dp = diskhelpers.disk_io(disk, .Read, header.partitionEntryLba, entriesBuf, prpBuf) or_return
	diskhelpers.wait(dp) or_return
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

	dps := make([dynamic]diskhelpers.DiskPending, 0, len(partitions))
	defer delete(dps)
	for partition, i in partitions {
		buf := partitionsBuf[i * shared.PAGE_SIZE:][:shared.PAGE_SIZE]
		submitErr := diskhelpers.disk_submit(disk, &dps, .Read, partition.firstLba, buf)
		if submitErr != .None {
			diskhelpers.wait_all(dps[:])
			return fses, submitErr
		}
	}
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
