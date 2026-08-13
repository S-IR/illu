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
// buddyInitialized: bool
trampolinePhys: u64 = 0x8000

men_init :: proc(
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapSize: u64,
	memoryMapDescSize: u64,
	kernelImg: elf.Image,
	adamImg: ^elf.Image,
) {

	assert(memoryMapDescSize != 0, "mem_init: zero descriptor size")
	assert(memoryMapSize >= memoryMapDescSize, "mem_init: memory map smaller than one descriptor")

	entryCount := memoryMapSize / memoryMapDescSize


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
	bitmapPagesNeeded := bitmap_pages_needed(totalPages)

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


	for seg in kernelImg.segments {
		segmentStart := seg.base / shared.PAGE_SIZE
		segmentEnd := pages_needed(seg.end)
		for pg in segmentStart ..< segmentEnd {
			kset(&state, pg)
		}
	}
	kernelStart := kernelImg.base / shared.PAGE_SIZE
	kernelEnd := pages_needed(kernelImg.end)
	for pg in kernelStart ..< kernelEnd do kset(&state, pg)

	adamStart := adamImg.base / shared.PAGE_SIZE
	adamEnd := pages_needed(adamImg.end)
	for pg in adamStart ..< adamEnd {
		kset(&state, pg)
	}

	TRAMPOLINE_LOW_LIMIT: u64 : shared.PAGE_SIZE
	TRAMPOLINE_HIGH_LIMIT: u64 : mem.Megabyte

	kset(&state, trampolinePhys / shared.PAGE_SIZE)
	print.kensure(trampolinePhys != 0, "pmm: no free page below 1mb for trampoline")


	mmapBase := u64(uintptr(rawptr(memoryMap)))
	mmapStart := mmapBase / shared.PAGE_SIZE
	mmapEnd := pages_needed(mmapBase + memoryMapSize)
	for pg in mmapStart ..< mmapEnd {
		kset(&state, pg)
	}

	buddyMetaStart := u64(uintptr(&freeLists[0])) / shared.PAGE_SIZE
	buddyMetaEnd := pages_needed(u64(uintptr(&freeLists[0])) + size_of(freeLists))
	for pg in buddyMetaStart ..< buddyMetaEnd {
		kset(&state, pg)
	}
	paging_init(kernelImg, memoryMap, memoryMapSize, memoryMapDescSize)
	buddy_init()


	buddy_release_range(mmapStart, mmapEnd)

	adamSize := adamImg.end - adamImg.base
	newAdamBase := palloc_zeroed(pages_needed(adamSize) * shared.PAGE_SIZE)
	print.kensure(newAdamBase != 0, "pmm: failed adam reallocation")
	mem.copy(rawptr(uintptr(newAdamBase)), rawptr(uintptr(adamImg.base)), int(adamSize))

	delta := newAdamBase - adamImg.base
	adamImg.entry += delta
	adamImg.base = newAdamBase
	adamImg.end = newAdamBase + adamSize

	for &seg in adamImg.segments {
		seg.base += delta
		seg.end += delta
	}
	for pg in adamStart ..< adamEnd {
		kclear(&state, pg)
	}
	print.serial_writeln("pmm: loaded")

}

kset :: #force_inline proc "contextless" (p: ^PMM, i: u64) {
	print.kassert(i < p.totalPages, "pmm set: page beyond bitmap")
	p.bitmap[i / 64] |= u64(1) << (i % 64)
}
kclear :: #force_inline proc "contextless" (p: ^PMM, i: u64) {
	print.kassert(i < p.totalPages, "pmm clear: page beyond bitmap")
	p.bitmap[i / 64] &= ~(u64(1) << (i % 64))
}
is_used :: #force_inline proc "contextless" (p: ^PMM, i: u64) -> bool {
	print.kassert(i < p.totalPages, "pmm test: page beyond bitmap")
	return p.bitmap[i / 64] >> (i % 64) & 1 != 0
}

when ODIN_TEST {
	@(thread_local)
	buddyMapBase: u64
	page_to_rawptr :: #force_inline proc "contextless" (page: u64) -> rawptr {
		return rawptr(uintptr(buddyMapBase + page * shared.PAGE_SIZE))
	}
	rawptr_to_page :: #force_inline proc "contextless" (ptr: rawptr) -> u64 {
		return (u64(uintptr(ptr)) - buddyMapBase) / shared.PAGE_SIZE
	}
} else {
	page_to_rawptr :: #force_inline proc "contextless" (page: u64) -> rawptr {
		return rawptr(uintptr(page * shared.PAGE_SIZE))
	}
	rawptr_to_page :: #force_inline proc "contextless" (ptr: rawptr) -> u64 {
		return u64(uintptr(ptr)) / shared.PAGE_SIZE
	}
}
pages_needed :: proc "contextless" (bytes: u64) -> u64 {
	return (bytes + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE
}
addr_round_up_to_page :: proc(addr: u64) -> u64 {
	return (addr + shared.PAGE_SIZE - 1) & ~u64(shared.PAGE_SIZE - 1)
}
addr_round_down_to_page :: proc(addr: u64) -> u64 {
	return addr & ~u64(shared.PAGE_SIZE - 1)
}
order_for :: proc "contextless" (n: u64) -> (order: u8 = 0) {
	size := u64(1)
	for size < n {
		size <<= 1
		order += 1
	}
	return order
}
@(private)
palloc :: proc "contextless" (sizeInBytes: u64) -> u64 {
	print.kassert(sizeInBytes != 0, "palloc: zero-size allocation")
	spinlock.lock(&state.lock)
	defer spinlock.unlock(&state.lock)

	pages := pages_needed(sizeInBytes)
	order := order_for(pages)
	return buddy_alloc(order)
}
@(private)
palloc_zeroed :: proc "contextless" (bytes: u64) -> u64 {
	addr := palloc(bytes)
	if addr == 0 || addr == max(u64) do return max(u64)
	print.kassert(addr % shared.PAGE_SIZE == 0, "palloc_zeroed: unaligned allocation")
	mem.zero(rawptr(uintptr(addr)), int(bytes))
	return addr
}

@(private)
pfree :: proc "contextless" (addr: u64, bytes: u64) {
	print.kassert(addr != 0, "pfree: null physical address")
	print.kassert(addr % shared.PAGE_SIZE == 0, "pfree: unaligned physical address")
	print.kassert(bytes != 0, "pfree: zero-size allocation")
	spinlock.lock(&state.lock)
	defer spinlock.unlock(&state.lock)

	pages := pages_needed(bytes)
	order := order_for(pages)
	buddy_free(addr, order)
}

alloc_pages :: proc "contextless" (bytes: u64) -> u64 {
	return palloc(bytes)
}

free_pages :: proc "contextless" (addr, bytes: u64) {
	pfree(addr, bytes)
}

alloc_zeroed :: proc "contextless" (bytes: u64) -> u64 {
	print.kassert(bytes != 0, "alloc_zeroed: zero-size allocation")
	return palloc_zeroed(bytes)
}
mmap_desc :: #force_inline proc(
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapDescSize: u64,
	i: u64,
) -> ^uefi.EFI_MEMORY_DESCRIPTOR {
	return (^uefi.EFI_MEMORY_DESCRIPTOR)(
		uintptr(rawptr(memoryMap)) + uintptr(i * memoryMapDescSize),
	)
}
early_alloc_page :: proc() -> u64 {
	for i in u64(0) ..< state.totalPages {
		if !is_used(&state, i) {
			kset(&state, i)
			return i * shared.PAGE_SIZE
		}
	}
	return 0 // no free page left
}
