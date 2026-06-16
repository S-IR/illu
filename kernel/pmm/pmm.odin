package pmm
import "../../lib/elf"
import "../../lib/shared"
import "../../lib/spinlock"
import "../../uefi"
import "../print"
import "core:mem"
PMM :: struct #all_or_none {
	bitmap:     []u64,
	totalPages: u64,
	lock:       spinlock.Spinlock,
}
when ODIN_TEST {
	@(thread_local)
	state: PMM
} else {
	state: PMM

}

men_init :: proc(
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapSize: u64,
	memoryMapDescSize: u64,
	kernelImg: elf.Image,
) {

	assert(memoryMapDescSize != 0, "mem_init: zero descriptor size")
	assert(memoryMapSize >= memoryMapDescSize, "mem_init: memory map smaller than one descriptor")

	entryCount := memoryMapSize / memoryMapDescSize

	mmap_desc :: #force_inline proc(
		memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
		memoryMapDescSize: u64,
		i: u64,
	) -> ^uefi.EFI_MEMORY_DESCRIPTOR {
		return (^uefi.EFI_MEMORY_DESCRIPTOR)(
			uintptr(rawptr(memoryMap)) + uintptr(i * memoryMapDescSize),
		)
	}
	is_good_ram :: #force_inline proc(t: uefi.EFI_MEMORY_TYPE) -> bool {
		return(
			t != .ReservedMemoryType &&
			t != .MemoryMappedIO &&
			t != .MemoryMappedIOPortSpace &&
			t != .UnusableMemory \
		)
	}
	totalPages: u64 = 0
	topPhys: u64 = 0
	haveConventional := false
	for i in 0 ..< entryCount {
		desc := mmap_desc(memoryMap, memoryMapDescSize, i)
		end := desc.PhysicalStart + desc.NumberOfPages * shared.PAGE_SIZE
		if end > topPhys do topPhys = end
		if desc.Type == .ConventionalMemory do haveConventional = true
		if !is_good_ram(desc.Type) do continue
		if end / shared.PAGE_SIZE > totalPages do totalPages = end / shared.PAGE_SIZE
	}
	print.kensure(haveConventional && totalPages != 0, "no conventional memory found")

	bitmapAddr: u64 = 0
	bitmapDesc: ^uefi.EFI_MEMORY_DESCRIPTOR
	bitmap_pages_needed :: proc(total: u64) -> u64 {return(
			(total / 8 + shared.PAGE_SIZE - 1) /
			shared.PAGE_SIZE \
		)}
	bitmapPagesNeeded := bitmap_pages_needed(totalPages / 8)

	for i in u64(0) ..< entryCount {
		desc := mmap_desc(memoryMap, memoryMapDescSize, i)
		if desc.Type != .ConventionalMemory do continue
		TOP_OF_MEM_USED_BY_LEGACY_SYSTEMS :: u64(0x100000)
		if desc.PhysicalStart < TOP_OF_MEM_USED_BY_LEGACY_SYSTEMS do continue
		if desc.NumberOfPages >= bitmapPagesNeeded {

			bitmapAddr = desc.PhysicalStart
			bitmapDesc = desc
			break
		}
	}
	print.kensure(bitmapDesc != nil, "no region large enough for pmm bitmap")
	assert(bitmapAddr % shared.PAGE_SIZE == 0, "pmm bitmap not page-aligned")

	bitmapWords := (totalPages + 63) / 64
	state.bitmap = mem.slice_ptr(cast(^u64)uintptr(bitmapAddr), int(bitmapWords))
	state.totalPages = totalPages

	memset_u64 :: proc "c" (dest: rawptr, c: u8, n: u64) -> rawptr {
		d := ([^]u8)(dest)
		for i in 0 ..< n do d[i] = c
		return dest
	}

	memset_u64(raw_data(state.bitmap), 0xFF, (totalPages + 7) / 8)
	bitmapPageStart := bitmapAddr / shared.PAGE_SIZE
	for pg in bitmapPageStart + bitmapPagesNeeded ..< bitmapPageStart + bitmapDesc.NumberOfPages {
		kclear(&state, pg)
	}
	for i in u64(0) ..< entryCount {
		desc := mmap_desc(memoryMap, memoryMapDescSize, i)

		isConventional := desc.Type == .ConventionalMemory
		isReclaimable := desc.Type == .LoaderCode || desc.Type == .LoaderData
		if !isConventional && !isReclaimable do continue
		if isConventional && desc.PhysicalStart == bitmapAddr do continue

		pageStart := max(desc.PhysicalStart / shared.PAGE_SIZE, u64(1))
		for pg in pageStart ..< pageStart + desc.NumberOfPages {
			kclear(&state, pg)
		}
	}

	kernelStart := kernelImg.base / shared.PAGE_SIZE
	kernelEnd := pages_needed(kernelImg.end)
	for pg in kernelStart ..< kernelEnd {
		kset(&state, pg)
	}
	buddy_init()

	paging_init(kernelImg)

	print.serial_writeln("pmm: loaded")

}

kset :: #force_inline proc(p: ^PMM, i: u64) {
	assert(i < p.totalPages, "pmm set: page beyond bitmap")
	p.bitmap[i / 64] |= u64(1) << (i % 64)
}
kclear :: #force_inline proc(p: ^PMM, i: u64) {
	assert(i < p.totalPages, "pmm clear: page beyond bitmap")
	p.bitmap[i / 64] &= ~(u64(1) << (i % 64))
}
is_used :: #force_inline proc(p: ^PMM, i: u64) -> bool {
	assert(i < p.totalPages, "pmm test: page beyond bitmap")
	return p.bitmap[i / 64] >> (i % 64) & 1 != 0
}

when ODIN_TEST {
	@(thread_local)
	buddyMapBase: u64
	page_to_rawptr :: #force_inline proc(page: u64) -> rawptr {
		return rawptr(uintptr(buddyMapBase + page * shared.PAGE_SIZE))
	}
	rawptr_to_page :: #force_inline proc(ptr: rawptr) -> u64 {
		return (u64(uintptr(ptr)) - buddyMapBase) / shared.PAGE_SIZE
	}
} else {
	page_to_rawptr :: #force_inline proc(page: u64) -> rawptr {
		return rawptr(uintptr(page * shared.PAGE_SIZE))
	}
	rawptr_to_page :: #force_inline proc(ptr: rawptr) -> u64 {
		return u64(uintptr(ptr)) / shared.PAGE_SIZE
	}
}
pages_needed :: proc(bytes: u64) -> u64 {
	return (bytes + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE
}
addr_round_up_to_page :: proc(addr: u64) -> u64 {
	return (addr + shared.PAGE_SIZE - 1) & ~u64(shared.PAGE_SIZE - 1)
}
addr_round_down_to_page :: proc(addr: u64) -> u64 {
	return addr & ~u64(shared.PAGE_SIZE - 1)
}
order_for :: proc(n: u64) -> (order: u8 = 0) {
	size := u64(1)
	for size < n {
		size <<= 1
		order += 1
	}
	return order
}
pmm_alloc :: proc(bytes: u64) -> u64 {
	spinlock.lock(&state.lock)
	defer spinlock.unlock(&state.lock)

	pages := pages_needed(bytes)
	order := order_for(pages)
	return buddy_alloc(order)
}
pmm_free :: proc(addr: u64, bytes: u64) {
	spinlock.lock(&state.lock)
	defer spinlock.unlock(&state.lock)

	pages := pages_needed(bytes)
	order := order_for(pages)
	buddy_free(addr, order)
}
