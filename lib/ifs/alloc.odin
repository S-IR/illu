package ifs

import "../shared"
import "base:intrinsics"
import "core:slice"
Extent :: struct {
	block, count: u64,
}

DiskAllocator :: struct {
	free:       [dynamic]Extent,
	blockCount: u64,
}

disk_allocator_init :: proc(
	alloc: ^DiskAllocator,
	blockCount: u64,
	used: []Extent,
) -> (
	err: shared.Error,
) {

	if !shared.assert(alloc != nil && len(alloc.free) == 0) do return .InvalidAPICall
	defer if err != .None do clear(&alloc.free)
	alloc.blockCount = blockCount
	slice.sort_by(used, proc(a, b: Extent) -> bool {
		return a.block < b.block
	})
	if !shared.assert(len(used) > 0 && used[0].block == 0) do return .InvalidAPICall

	next := u64(0)
	for extent in used {
		if !shared.assert(extent.count > 0) do return .InvalidAPICall


		if extent.block < next do return .Corrupt
		if extent.block > blockCount || extent.count > blockCount - extent.block do return .Corrupt
		if extent.block > next {
			_, aErr := append(&alloc.free, Extent{block = next, count = extent.block - next})
			if aErr != nil do return .OutOfMemory
		}
		next = extent.block + extent.count
	}
	if next < blockCount {
		_, aErr := append(&alloc.free, Extent{block = next, count = blockCount - next})
		if aErr != nil do return .OutOfMemory

	}
	return .None
}

disk_free :: proc(alloc: ^DiskAllocator, block, count: u64) -> shared.Error {
	if !shared.assert(alloc != nil) do return .InvalidAPICall

	if !shared.assert(block > 0) do return .InvalidAPICall
	if !shared.assert(count > 0) do return .InvalidAPICall

	blockUpperBound, overflown := intrinsics.overflow_add(block, count)
	if !shared.assert(!overflown) do return .InvalidAPICall
	if !shared.assert(blockUpperBound <= alloc.blockCount) do return .InvalidAPICall


	i, found := slice.binary_search_by(
		alloc.free[:],
		block,
		proc(extent: Extent, key: u64) -> slice.Ordering {
			return slice.cmp(extent.block, key)
		},
	)
	if !shared.assert(!found) do return .InvalidAPICall

	hasPrev := i > 0
	hasNext := i < len(alloc.free)
	fitsPrev := !hasPrev || alloc.free[i - 1].block + alloc.free[i - 1].count <= block
	fitsNext := !hasNext || blockUpperBound <= alloc.free[i].block
	if !shared.assert(fitsPrev && fitsNext) do return .InvalidAPICall

	touchesPrev := hasPrev && alloc.free[i - 1].block + alloc.free[i - 1].count == block
	touchesNext := hasNext && block + count == alloc.free[i].block

	switch {
	case touchesPrev && touchesNext:
		alloc.free[i - 1].count += count + alloc.free[i].count
		ordered_remove(&alloc.free, i)
	case touchesPrev:
		alloc.free[i - 1].count += count
	case touchesNext:
		alloc.free[i].block = block
		alloc.free[i].count += count
	case:
		_, err := inject_at(&alloc.free, i, Extent{block = block, count = count})
		if err != nil do return .OutOfMemory
	}
	return .None
}
disk_alloc :: proc(alloc: ^DiskAllocator, count: u64) -> (block: u64, err: shared.Error) {
	if !shared.assert(alloc != nil) do return 0, .InvalidAPICall

	if !shared.assert(count > 0) do return 0, .InvalidAPICall

	for &extent, i in alloc.free {
		assert(extent.block > 0)
		assert(extent.count > 0)

		if extent.count < count do continue
		block = extent.block
		extent.block += count
		extent.count -= count
		if extent.count == 0 do ordered_remove(&alloc.free, i)
		return block, .None
	}
	return 0, .FsDiskFull
}
