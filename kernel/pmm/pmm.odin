package pmm
import "../../lib/elf"
import "../../lib/shared"
import "../../lib/spinlock"
import "../../uefi"
import "../print"
import "core:mem"
import "core:slice"
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
TRAMPOLINE_PHYS :: u64(0x8000)

men_init :: proc(
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapSize: u64,
	memoryMapDescSize: u64,
	kernelImg: elf.ElfImage,
	adamImg: elf.ElfImage,
	reserved: [][]byte,
	globalKernel: bool,
	has1GBPages: bool,
) {

	assert(memoryMapDescSize != 0, "mem_init: zero descriptor size")
	assert(memoryMapSize >= memoryMapDescSize, "mem_init: memory map smaller than one descriptor")

	entryCount := memoryMapSize / memoryMapDescSize

	totalPages: u64 = 0
	haveConventional := false
	trampolineUsable := false
	for i in 0 ..< entryCount {
		desc := mmap_desc(memoryMap, memoryMapDescSize, i)
		end := desc.PhysicalStart + desc.NumberOfPages * shared.PAGE_SIZE
		if desc.Type == .ConventionalMemory do haveConventional = true
		if TRAMPOLINE_PHYS >= desc.PhysicalStart && TRAMPOLINE_PHYS < end {
			#partial switch desc.Type {
			case .ConventionalMemory, .BootServicesCode, .BootServicesData, .LoaderCode, .LoaderData:
				trampolineUsable = true
			}
		}
		if !is_good_ram(desc.Type) do continue
		if end / shared.PAGE_SIZE > totalPages do totalPages = end / shared.PAGE_SIZE
	}
	print.kensure(haveConventional && totalPages != 0, "no conventional memory found")
	print.kensure(trampolineUsable, "pmm: trampoline page is not free ram")

	bitmapAddr: u64 = 0
	bitmapDesc: ^uefi.EFI_MEMORY_DESCRIPTOR
	bitmapWords := (totalPages + 63) / 64
	bitmapPagesNeeded := pages_needed(bitmapWords * size_of(u64))

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

	state.bitmap = mem.slice_ptr(cast(^u64)uintptr(bitmapAddr), int(bitmapWords))
	state.totalPages = totalPages
	slice.fill(state.bitmap, max(u64))

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

		pageStart := desc.PhysicalStart / shared.PAGE_SIZE
		for pg in max(pageStart, 1) ..< pageStart + desc.NumberOfPages {
			kclear(&state, pg)
		}
	}


	for img in ([]elf.ElfImage{kernelImg, adamImg}) {
		for pg in img.base / shared.PAGE_SIZE ..< pages_needed(img.end) do kset(&state, pg)
	}
	kset(&state, TRAMPOLINE_PHYS / shared.PAGE_SIZE)

	mmapBase := u64(uintptr(rawptr(memoryMap)))
	mmapStart := mmapBase / shared.PAGE_SIZE
	mmapEnd := pages_needed(mmapBase + memoryMapSize)
	for pg in mmapStart ..< mmapEnd {
		kset(&state, pg)
	}

	for r in reserved {
		base := u64(uintptr(raw_data(r)))
		for pg in base / shared.PAGE_SIZE ..< pages_needed(base + u64(len(r))) {
			kset(&state, pg)
		}
	}

	buddyMetaStart := u64(uintptr(&freeLists[0])) / shared.PAGE_SIZE
	buddyMetaEnd := pages_needed(u64(uintptr(&freeLists[0])) + size_of(freeLists))
	for pg in buddyMetaStart ..< buddyMetaEnd {
		kset(&state, pg)
	}
	paging_init(kernelImg, memoryMap, memoryMapSize, memoryMapDescSize, globalKernel, has1GBPages)
	buddy_init()


	buddy_release_range(mmapStart, mmapEnd)

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

page_to_rawptr :: #force_inline proc "contextless" (page: u64) -> rawptr {
	return phys_to_ptr(page * shared.PAGE_SIZE)
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
	if addr == 0 do return 0
	print.kassert(addr % shared.PAGE_SIZE == 0, "palloc_zeroed: unaligned allocation")
	mem.zero(phys_to_ptr(addr), int(bytes))
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
is_good_ram :: #force_inline proc "contextless" (t: uefi.EFI_MEMORY_TYPE) -> bool {
	return(
		t != .ReservedMemoryType &&
		t != .MemoryMappedIO &&
		t != .MemoryMappedIOPortSpace &&
		t != .UnusableMemory \
	)
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
