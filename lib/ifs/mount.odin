package ifs

import "../alloc"
import "../diskhelpers"
import "../gpt"
import "../nvme"
import "../shared"
import "../syscalls"
import "base:intrinsics"
import "core:hash"
import "core:mem"

mount :: proc(
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

	dmaPage := alloc.dma_pages(1) or_return
	firstBlock := mem.byte_slice(rawptr(uintptr(dmaPage)), shared.PAGE_SIZE)[:disk.blockSize]
	defer syscalls.mem_free_userspace(dmaPage)
	dp := diskhelpers.disk_io(disk, .Read, partStart, firstBlock) or_return
	diskhelpers.wait(dp) or_return

	if !is(firstBlock) do return diskAlloc, .Corrupt
	sb := (^Superblock)(raw_data(firstBlock))^
	blockSize := u64(disk.blockSize)

	rootExtent := slot_extent(sb.root, blockSize, partBlocks) or_return

	used := make([dynamic]Extent, context.temp_allocator)
	if _, aErr := append(&used, rootExtent); aErr != .None do return diskAlloc, .OutOfMemory

	usedBlocks := rootExtent.count

	level := make([dynamic]Slot, context.temp_allocator)

	if _, aErr := append(&level, sb.root); aErr != .None do return diskAlloc, .OutOfMemory

	dirsDma: u64 = 0
	dirsDmaPageCount: u64 = 0
	defer if dirsDmaPageCount != 0 do syscalls.mem_free_userspace(dirsDma)


	namesDma: u64 = 0
	namesDmaPageCount: u64 = 0
	defer if namesDmaPageCount != 0 do syscalls.mem_free_userspace(namesDma)

	blocks := make([dynamic]u64, context.temp_allocator)
	bufs := make([dynamic][]byte, context.temp_allocator)
	dps := make([dynamic]diskhelpers.DiskPending, context.temp_allocator)
	nameSlots := make([dynamic]Slot, context.temp_allocator)
	nameBufs := make([dynamic][]byte, context.temp_allocator)

	aErr: mem.Allocator_Error
	for len(level) > 0 {
		totalPages: u64 = 0
		for slot in level {
			totalPages, overflown = intrinsics.overflow_add(page_count(slot.cap), totalPages)
			if overflown do return diskAlloc, .Corrupt
		}
		assert(totalPages > 0)
		if totalPages > dirsDmaPageCount {
			if dirsDmaPageCount != 0 do syscalls.mem_free_userspace(dirsDma)
			dirsDmaPageCount = 0
			dirsDma = alloc.dma_pages(totalPages) or_return
			dirsDmaPageCount = totalPages
		}
		if resize(&blocks, len(level)) != .None do return diskAlloc, .OutOfMemory
		if resize(&bufs, len(level)) != .None do return diskAlloc, .OutOfMemory
		clear(&dps)
		clear(&nameSlots)

		pageOff: u64 = 0
		for slot, i in level {
			blocks[i] = partStart + slot.offset / blockSize
			bufs[i] = mem.byte_slice(
				rawptr(uintptr(dirsDma + pageOff * shared.PAGE_SIZE)),
				int(slot.cap),
			)
			pageOff += page_count(slot.cap)
		}
		assert(pageOff == totalPages)

		prpDma, readErr := diskhelpers.disk_read_batch(disk, &dps, blocks[:], bufs[:])
		defer if prpDma != 0 do syscalls.mem_free_userspace(prpDma)
		waitErr := diskhelpers.wait_all(dps[:])
		if readErr != .None do return diskAlloc, readErr
		if waitErr != .None do return diskAlloc, waitErr

		for buf, d in bufs {
			hdr := (^DirHeader)(raw_data(buf))^
			if hdr.reserved != 0 do return diskAlloc, .Corrupt
			if hdr.count == 0 do return diskAlloc, .Corrupt
			if hdr.count > u64(len(buf) - size_of(DirHeader)) / u64(size_of(Slot)) do return diskAlloc, .Corrupt

			slots := mem.slice_ptr((^Slot)(raw_data(buf[size_of(DirHeader):])), int(hdr.count))
			if slots[0] == {} do return diskAlloc, .Corrupt
			if _, aErr = append(&nameSlots, slots[0]); aErr != .None do return diskAlloc, .OutOfMemory
			for slot in slots {
				if slot == {} do continue
				extent := slot_extent(slot, blockSize, partBlocks) or_return
				usedBlocks, overflown = intrinsics.overflow_add(usedBlocks, extent.count)
				if overflown do return diskAlloc, .Corrupt
				if usedBlocks > partBlocks - 1 do return diskAlloc, .Corrupt
				if _, aErr = append(&used, extent); aErr != .None do return diskAlloc, .OutOfMemory
			}


		}
		assert(len(nameSlots) == len(bufs))
		namePages: u64 = 0
		for nameSlot in nameSlots {
			namePages, overflown = intrinsics.overflow_add(page_count(nameSlot.cap), namePages)
			if overflown do return diskAlloc, .Corrupt

		}
		assert(namePages > 0)
		if namePages > namesDmaPageCount {
			if namesDmaPageCount != 0 do syscalls.mem_free_userspace(namesDma)
			namesDmaPageCount = 0
			namesDma = alloc.dma_pages(namePages) or_return
			namesDmaPageCount = namePages
		}
		if resize(&blocks, len(nameSlots)) != .None do return diskAlloc, .OutOfMemory
		if resize(&nameBufs, len(nameSlots)) != .None do return diskAlloc, .OutOfMemory
		pageOff = 0
		for slot, i in nameSlots {
			blocks[i] = partStart + slot.offset / blockSize
			nameBufs[i] = mem.byte_slice(
				rawptr(uintptr(namesDma + pageOff * shared.PAGE_SIZE)),
				int(slot.cap),
			)
			pageOff += page_count(slot.cap)
		}
		assert(pageOff == namePages)
		clear(&dps)
		namePrpDma: u64
		namePrpDma, readErr = diskhelpers.disk_read_batch(disk, &dps, blocks[:], nameBufs[:])
		defer if namePrpDma != 0 do syscalls.mem_free_userspace(namePrpDma)
		waitErr = diskhelpers.wait_all(dps[:])
		if readErr != .None do return diskAlloc, readErr
		if waitErr != .None do return diskAlloc, waitErr

		clear(&level)

		for buf, d in bufs {
			hdr := (^DirHeader)(raw_data(buf))^
			slots := mem.slice_ptr((^Slot)(raw_data(buf[size_of(DirHeader):])), int(hdr.count))
			refs := name_file_parse(nameBufs[d]) or_return
			chunkLinks := 0
			for ref in refs {
				if ref.slotIdx == 0 || ref.slotIdx >= hdr.count do return diskAlloc, .Corrupt
				if slots[ref.slotIdx] == {} do return diskAlloc, .Corrupt
				name := ref_name(nameBufs[d], ref)

				if name == CHUNK_LINK do chunkLinks += 1
				if chunkLinks > 1 do return diskAlloc, .Corrupt
				if is_dir_name(name) {
					if _, aErr = append(&level, slots[ref.slotIdx]); aErr != .None do return diskAlloc, .OutOfMemory
				}
			}


		}


	}
	return disk_allocator_init({1, partBlocks - 1}, used[:])
}
page_count :: proc(cap: u64) -> (res: u64) {
	res = cap / shared.PAGE_SIZE
	if cap % shared.PAGE_SIZE != 0 do res += 1
	return res
}
slot_extent :: proc(
	slot: Slot,
	blockSize, partBlocks: u64,
) -> (
	extent: Extent,
	err: shared.Error,
) {
	if !shared.assert(blockSize > 0) do return {}, .InvalidAPICall
	if !shared.assert(partBlocks > 0) do return {}, .InvalidAPICall

	if slot.cap == 0 do return {}, .Corrupt
	if slot.offset == 0 do return {}, .Corrupt

	if slot.cap % blockSize != 0 do return {}, .Corrupt
	if slot.offset % blockSize != 0 do return {}, .Corrupt

	slotUpperBound, overflown := intrinsics.overflow_add(
		slot.cap / blockSize,
		slot.offset / blockSize,
	)
	if overflown do return {}, .Corrupt
	if slotUpperBound > partBlocks do return {}, .Corrupt

	return {slot.offset / blockSize, slot.cap / blockSize}, .None
}
