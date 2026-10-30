package pmm
import ah "../../asm_helpers"
import "../../lib/elf"
import "../../lib/lmem"
import "../../lib/shared"
import "../../lib/spinlock"
import "../../uefi"
import "../print"
import "core:mem"
import "core:slice"
PMM :: struct #all_or_none {
	bitmap:             []u64,
	totalPages:         u64,
	lock:               spinlock.Spinlock,
	freeLists:          [PMM_BUDDY_MAX_ORDER]FreeBlock,
	earlyAllocNextPage: u64,
}
TRAMPOLINE_PHYS :: u64(0x8000)

men_init :: proc(
	p: ^PMM,
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
			case .ConventionalMemory,
			     .BootServicesCode,
			     .BootServicesData,
			     .LoaderCode,
			     .LoaderData:
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

	p.bitmap = mem.slice_ptr(cast(^u64)uintptr(bitmapAddr), int(bitmapWords))
	p.totalPages = totalPages
	slice.fill(p.bitmap, max(u64))

	bitmapPageStart := bitmapAddr / shared.PAGE_SIZE
	bitmap_fill(
		p,
		bitmapPageStart + bitmapPagesNeeded,
		bitmapPageStart + bitmapDesc.NumberOfPages,
		false,
	)
	for i in u64(0) ..< entryCount {
		desc := mmap_desc(memoryMap, memoryMapDescSize, i)

		isConventional := desc.Type == .ConventionalMemory
		isReclaimable := desc.Type == .LoaderCode || desc.Type == .LoaderData
		if !isConventional && !isReclaimable do continue
		if isConventional && desc.PhysicalStart == bitmapAddr do continue

		pageStart := desc.PhysicalStart / shared.PAGE_SIZE
		bitmap_fill(p, max(pageStart, 1), pageStart + desc.NumberOfPages, false)
	}


	for img in ([]elf.ElfImage{kernelImg, adamImg}) {
		bitmap_fill(p, img.base / shared.PAGE_SIZE, pages_needed(img.end), true)
	}
	kset(p, TRAMPOLINE_PHYS / shared.PAGE_SIZE)

	mmapBase := u64(uintptr(rawptr(memoryMap)))
	mmapStart := mmapBase / shared.PAGE_SIZE
	mmapEnd := pages_needed(mmapBase + memoryMapSize)
	bitmap_fill(p, mmapStart, mmapEnd, true)

	for r in reserved {
		base := u64(uintptr(raw_data(r)))
		bitmap_fill(p, base / shared.PAGE_SIZE, pages_needed(base + u64(len(r))), true)
	}

	buddyMetaStart := u64(uintptr(&p.freeLists[0])) / shared.PAGE_SIZE
	buddyMetaEnd := pages_needed(u64(uintptr(&p.freeLists[0])) + size_of(p.freeLists))
	bitmap_fill(p, buddyMetaStart, buddyMetaEnd, true)
	paging_init(p, kernelImg, memoryMap, memoryMapSize, memoryMapDescSize, globalKernel, has1GBPages)
	buddy_init(p)


	buddy_release_range(p, mmapStart, mmapEnd)

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
bitmap_fill :: proc "contextless" (p: ^PMM, start, end: u64, used: bool) {
	print.kassert(start <= end && end <= p.totalPages, "pmm fill: range beyond bitmap")
	for i := start; i < end; {
		bit := i % 64
		count := min(64 - bit, end - i)
		mask := (max(u64) >> (64 - count)) << bit
		if used {
			p.bitmap[i / 64] |= mask
		} else {
			p.bitmap[i / 64] &= ~mask
		}
		i += count
	}
}

bitmap_all_used :: proc "contextless" (p: ^PMM, start, end: u64) -> bool {
	print.kassert(start <= end && end <= p.totalPages, "pmm check: range beyond bitmap")
	for i := start; i < end; {
		bit := i % 64
		count := min(64 - bit, end - i)
		mask := (max(u64) >> (64 - count)) << bit
		if p.bitmap[i / 64] & mask != mask do return false
		i += count
	}
	return true
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
palloc :: proc "contextless" (p: ^PMM, sizeInBytes: u64) -> u64 {
	print.kassert(sizeInBytes != 0, "palloc: zero-size allocation")
	pmmGuards := [][]u8{mem.ptr_to_bytes(p), mem.slice_to_bytes(p.bitmap)}
	spinlock.lock(&p.lock, pmmGuards)
	defer spinlock.unlock(&p.lock, pmmGuards)

	pages := pages_needed(sizeInBytes)
	order := order_for(pages)
	addr := buddy_alloc(p, order)
	if addr == 0 do return 0
	tail := addr / shared.PAGE_SIZE + pages
	blockEnd := addr / shared.PAGE_SIZE + (u64(1) << order)
	if tail < blockEnd do buddy_release_range(p, tail, blockEnd)
	return addr
}
@(private)
palloc_zeroed :: proc "contextless" (p: ^PMM, bytes: u64) -> u64 {
	addr := palloc(p, bytes)
	if addr == 0 do return 0
	print.kassert(addr % shared.PAGE_SIZE == 0, "palloc_zeroed: unaligned allocation")
	NON_TEMPORAL_ZERO_MIN :: 256 * mem.Kilobyte
	if bytes >= NON_TEMPORAL_ZERO_MIN {
		ah.zero_nontemporal(phys_to_ptr(addr), pages_needed(bytes) * shared.PAGE_SIZE)
	} else {
		mem.zero(phys_to_ptr(addr), int(bytes))
	}
	return addr
}

@(private)
pfree :: proc "contextless" (p: ^PMM, addr: u64, bytes: u64) {
	print.kassert(addr != 0, "pfree: null physical address")
	print.kassert(addr % shared.PAGE_SIZE == 0, "pfree: unaligned physical address")
	print.kassert(bytes != 0, "pfree: zero-size allocation")
	pmmGuards := [][]u8{mem.ptr_to_bytes(p), mem.slice_to_bytes(p.bitmap)}
	spinlock.lock(&p.lock, pmmGuards)
	defer spinlock.unlock(&p.lock, pmmGuards)

	end := addr / shared.PAGE_SIZE + pages_needed(bytes)
	for page := addr / shared.PAGE_SIZE; page < end; {
		order := largest_block_order(page, end)
		buddy_free(p, page * shared.PAGE_SIZE, order)
		page += u64(1) << order
	}
}

alloc_pages :: proc "contextless" (p: ^PMM, bytes: u64) -> u64 {
	return palloc(p, bytes)
}

free_pages :: proc "contextless" (p: ^PMM, addr, bytes: u64) {
	pfree(p, addr, bytes)
}

alloc_zeroed :: proc "contextless" (p: ^PMM, bytes: u64) -> u64 {
	print.kassert(bytes != 0, "alloc_zeroed: zero-size allocation")
	return palloc_zeroed(p, bytes)
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
map_kernel_mmio :: proc(p: ^PMM, phys, size: u64, pageSize: lmem.PageSize) {
	LIMIT :: KERNEL_ENTRY_REGION - KERNEL_DIRECT_MAP
	print.kensure(size <= LIMIT && phys <= LIMIT - size)
	pageBytes := lmem.page_bytes(pageSize)
	for offset: u64 = 0; offset < size; offset += pageBytes {
		print.kassert(slot_available(kernelPML4, KERNEL_DIRECT_MAP + phys + offset, pageSize))
		map_page(
			p,
			kernelPML4,
			phys + offset,
			KERNEL_DIRECT_MAP + phys + offset,
			pageSize,
			lmem.PageFlags{.Present, .Write, .NX, .PCD, .PWT} + kernelGlobalFlag,
		)
	}
}
