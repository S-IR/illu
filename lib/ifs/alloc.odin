package ifs

import "core:slice"
Extent :: struct {
	block, count: u64,
}

DiskAllocator :: struct {
	free: [dynamic]Extent,
}

disk_allocator_init :: proc(alloc: ^DiskAllocator, blockCount: u64, used: []Extent) -> Error {
	assert(len(alloc.free) == 0)
	slice.sort_by(used, proc(a, b: Extent) -> bool {
		return a.block < b.block
	})
	next := u64(0)
	for extent in used {
		assert(extent.count > 0)
		if extent.block < next do return .Corrupt
		if extent.block > blockCount || extent.count > blockCount - extent.block do return .Corrupt
		if extent.block > next {
			_, err := append(&alloc.free, Extent{block = next, count = extent.block - next})
			if err != nil do return .OutOfMemory
		}
		next = extent.block + extent.count
	}
	if next < blockCount {
		_, err := append(&alloc.free, Extent{block = next, count = blockCount - next})
		if err != nil do return .OutOfMemory

	}
	return nil
}

disk_free :: proc(alloc: ^DiskAllocator, block, count: u64) -> Error {
	assert(block > 0)
	assert(count > 0)

	i, found := slice.binary_search_by(
		alloc.free[:],
		block,
		proc(extent: Extent, key: u64) -> slice.Ordering {
			return slice.cmp(extent.block, key)
		},
	)
	assert(!found)
	hasPrev := i > 0
	hasNext := i < len(alloc.free)
	if hasPrev do assert(alloc.free[i - 1].block + alloc.free[i - 1].count <= block)
	if hasNext do assert(block + count <= alloc.free[i].block)

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
	return nil
}
disk_alloc :: proc(alloc: ^DiskAllocator, count: u64) -> (block: u64, err: Error) {
	assert(count > 0)
	for &extent, i in alloc.free {
		assert(extent.block > 0)
		assert(extent.count > 0)
		if extent.count < count do continue
		block = extent.block
		extent.block += count
		extent.count -= count
		if extent.count == 0 do ordered_remove(&alloc.free, i)
		return block, nil
	}
	return 0, .DiskFull
}
