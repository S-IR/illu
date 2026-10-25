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
	root: Slot,
	err: shared.Error,
) {
	if !shared.assert(disk != nil) do return diskAlloc, {}, .InvalidAPICall
	if !shared.assert(shared.PAGE_SIZE % disk.blockSize == 0) do return diskAlloc, {}, .InvalidAPICall
	if !shared.assert(partBlocks > 1) do return diskAlloc, {}, .InvalidAPICall
	partUpperBound, overflown := intrinsics.overflow_add(partStart, partBlocks)
	if !shared.assert(!overflown) do return diskAlloc, {}, .InvalidAPICall
	if !shared.assert(partUpperBound <= disk.blockCount) do return diskAlloc, {}, .InvalidAPICall

	firstBlock, sbAllocErr := make_aligned([]byte, disk.blockSize, shared.PAGE_SIZE, context.temp_allocator)
	if sbAllocErr != nil do return diskAlloc, {}, .OutOfMemory
	dps := make([dynamic]diskhelpers.DiskPending, context.temp_allocator)
	diskhelpers.disk_io(disk, &dps, .Read, {partStart}, {firstBlock}) or_return
	diskhelpers.wait_all(dps[:]) or_return

	if !is(firstBlock) do return diskAlloc, {}, .Corrupt
	sb := (^Superblock)(raw_data(firstBlock))^
	blockSize := u64(disk.blockSize)

	rootExtent := slot_extent(sb.root, blockSize, partBlocks) or_return

	used := make([dynamic]Extent, context.temp_allocator)
	if _, aErr := append(&used, rootExtent); aErr != .None do return diskAlloc, sb.root, .OutOfMemory

	usedBlocks := rootExtent.count

	level := make([dynamic]Slot, context.temp_allocator)

	if _, aErr := append(&level, sb.root); aErr != .None do return diskAlloc, sb.root, .OutOfMemory

	for len(level) > 0 {
		dirBufs, nameBufs := dirs_read(disk, partStart, partBlocks, level[:]) or_return
		clear(&level)

		for buf, d in dirBufs {
			hdr, slots := dir_parse(buf) or_return
			for slot in slots {
				if slot == {} do continue
				extent := slot_extent(slot, blockSize, partBlocks) or_return
				usedBlocks, overflown = intrinsics.overflow_add(usedBlocks, extent.count)
				if overflown do return diskAlloc, sb.root, .Corrupt
				if usedBlocks > partBlocks - 1 do return diskAlloc, sb.root, .Corrupt
				if _, aErr := append(&used, extent); aErr != .None do return diskAlloc, sb.root, .OutOfMemory
			}

			if nameBufs[d] == nil do continue
			refs, parseErr := name_file_parse(nameBufs[d])
			if parseErr == .Corrupt do continue
			if parseErr != .None do return diskAlloc, sb.root, parseErr
			for ref in refs {
				if ref.slotIdx == 0 || ref.slotIdx >= hdr.count do return diskAlloc, sb.root, .Corrupt
				if slots[ref.slotIdx] == {} do return diskAlloc, sb.root, .Corrupt
				if !is_dir_name(ref_name(nameBufs[d], ref)) do continue
				if _, aErr := append(&level, slots[ref.slotIdx]); aErr != .None do return diskAlloc, sb.root, .OutOfMemory
			}
		}
	}
	diskAlloc, err = disk_allocator_init({1, partBlocks - 1}, used[:])
	return diskAlloc, sb.root, err
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
