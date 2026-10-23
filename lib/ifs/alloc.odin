package ifs

import "../shared"
import "base:intrinsics"
import "core:slice"
Extent :: struct {
	block, count: u64,
}

DiskAllocator :: struct {
	free:  [dynamic]Extent,
	range: Extent,
}

disk_allocator_init :: proc(
	range: Extent,
	used: []Extent,
) -> (
	diskAlloc: DiskAllocator,
	err: shared.Error,
) {

	free: [dynamic]Extent
	defer if err != .None do delete(free)
	if !shared.assert(range.count > 0) do return {}, .InvalidAPICall
	rangeUpperBound, overflown := intrinsics.overflow_add(range.block, range.count)
	if !shared.assert(!overflown) do return {}, .InvalidAPICall


	slice.sort_by(used, proc(a, b: Extent) -> bool {
		return a.block < b.block
	})

	next := range.block
	for extent in used {
		if !shared.assert(extent.count > 0) do return {}, .InvalidAPICall


		if extent.block < next do return {}, .Corrupt
		if extent.block > rangeUpperBound || extent.count > rangeUpperBound - extent.block do return {}, .Corrupt
		if extent.block > next {
			_, aErr := append(&free, Extent{block = next, count = extent.block - next})
			if aErr != nil do return {}, .OutOfMemory
		}
		next = extent.block + extent.count
	}
	if next < rangeUpperBound {
		_, aErr := append(&free, Extent{block = next, count = rangeUpperBound - next})
		if aErr != nil do return {}, .OutOfMemory

	}
	return DiskAllocator{free = free, range = range}, .None
}

disk_free :: proc(alloc: ^DiskAllocator, block, count: u64) -> shared.Error {
	if !shared.assert(alloc != nil) do return .InvalidAPICall

	if !shared.assert(block >= alloc.range.block) do return .InvalidAPICall
	if !shared.assert(count > 0) do return .InvalidAPICall

	blockUpperBound, overflown := intrinsics.overflow_add(block, count)
	if !shared.assert(!overflown) do return .InvalidAPICall
	if !shared.assert(blockUpperBound <= alloc.range.block + alloc.range.count) do return .InvalidAPICall


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
		assert(extent.block >= alloc.range.block)
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
