package pmm
import ah "../../asm_helpers"
import "../../lib/elf"
import "../../lib/lmem"
import "../../lib/shared"
import "../../uefi"
import "../print"
import "core:mem"

KERNEL_DIRECT_MAP :: u64(0xFFFF_8000_0000_0000)
KERNEL_ENTRY_REGION :: u64(0xFFFF_C000_0000_0000)
KERNEL_ENTRY_REGION_END :: KERNEL_ENTRY_REGION + (u64(1) << PT_SHIFT_PML4)
KERNEL_HALF_FIRST_PML4_INDEX :: 256
ENTRY_REGION_PML4_INDEX :: (KERNEL_ENTRY_REGION >> PT_SHIFT_PML4) & PT_INDEX_MASK
#assert(ENTRY_REGION_PML4_INDEX == 384)
#assert((KERNEL_DIRECT_MAP >> PT_SHIFT_PML4) & PT_INDEX_MASK == KERNEL_HALF_FIRST_PML4_INDEX)

PT_SHIFT_PML4 :: u64(39)
PT_SHIFT_PDPT :: u64(30)
PT_SHIFT_PD :: u64(21)
PT_SHIFT_PT :: u64(12)
PT_INDEX_MASK :: u64(0x1FF)
PT_ENTRIES :: 512
ENTRY_ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)
CR4_PGE :: u64(1) << 7

@(export, link_name = "kernelPML4")
kernelPML4: u64

kernelImgGlobal: elf.ElfImage
kernelGlobalFlag: lmem.PageFlags
pages1GB: bool
entryRegionNext: u64 = KERNEL_ENTRY_REGION

when ODIN_TEST {
	@(thread_local)
	directMapBase: u64
} else {
	directMapBase: u64
}

phys_to_ptr :: #force_inline proc "contextless" (phys: u64) -> rawptr {
	return rawptr(uintptr(phys + directMapBase))
}

ptr_to_phys :: #force_inline proc "contextless" (p: rawptr) -> u64 {
	addr := u64(uintptr(p))
	print.kassert(addr >= directMapBase)
	return addr - directMapBase
}

phys_to_slice :: proc "contextless" (s: []$T) -> []T {
	return ([^]T)(phys_to_ptr(u64(uintptr(raw_data(s)))))[:len(s)]
}

paging_init :: proc(
	kernelImg: elf.ElfImage,
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapSize: u64,
	memoryMapDescSize: u64,
	globalKernel: bool,
	has1GBPages: bool,
) {
	kernelImgGlobal = kernelImg
	kernelGlobalFlag = {.Global} if globalKernel else {}
	pages1GB = has1GBPages
	print.kensure(state.totalPages * shared.PAGE_SIZE <= KERNEL_ENTRY_REGION - KERNEL_DIRECT_MAP, "paging_init: ram larger than the direct map")

	enable_nxe()
	kernelPML4 = early_alloc_zeroed_page(u64(4) * u64(mem.Gigabyte))
	print.kensure(kernelPML4 != 0, "paging_init: no page below 4 GiB for kernel PML4")

	pml4 := ([^]u64)(phys_to_ptr(kernelPML4))
	for i in KERNEL_HALF_FIRST_PML4_INDEX ..< PT_ENTRIES {
		table := early_alloc_zeroed_page()
		print.kensure(table != 0, "paging_init: out of memory for kernel half")
		pml4[i] = table | transmute(u64)lmem.PageFlags{.Present, .Write}
	}

	directFlags := lmem.PageFlags{.Present, .Write, .NX} + kernelGlobalFlag
	for i in u64(0) ..< memoryMapSize / memoryMapDescSize {
		desc := mmap_desc(memoryMap, memoryMapDescSize, i)
		if !is_good_ram(desc.Type) do continue
		end := desc.PhysicalStart + desc.NumberOfPages * shared.PAGE_SIZE
		print.kassert(end / shared.PAGE_SIZE <= state.totalPages)
		for phys := desc.PhysicalStart; phys < end; {
			size := largest_page_fitting(phys, end)
			map_page(kernelPML4, phys, KERNEL_DIRECT_MAP + phys, size, directFlags, bootstrap = true)
			phys += lmem.page_bytes(size)
		}
	}

	map_kernel_image(kernelPML4, bootstrap = true)
	map_page(kernelPML4, TRAMPOLINE_PHYS, TRAMPOLINE_PHYS, ._4KB, {.Present, .Write}, bootstrap = true)

	ah.write_cr3(kernelPML4)
	cr4 := ah.read_cr4()
	ah.write_cr4(cr4 & ~CR4_PGE)
	ah.write_cr4(cr4 | CR4_PGE)

	directMapBase = KERNEL_DIRECT_MAP
	state.bitmap = phys_to_slice(state.bitmap)
}

largest_page_fitting :: proc "contextless" (addr, end: u64) -> lmem.PageSize {
	for size in ([]lmem.PageSize{._1GB, ._2MB}) {
		if size == ._1GB && !pages1GB do continue
		bytes := lmem.page_bytes(size)
		if addr % bytes == 0 && end - addr >= bytes do return size
	}
	return ._4KB
}

map_kernel_image :: proc(dstPML4: u64, bootstrap := false) {
	for seg in kernelImgGlobal.segments {
		flags := lmem.PageFlags{.Present, .NX} + kernelGlobalFlag
		if .W in seg.perms do flags += {.Write}
		if .X in seg.perms do flags -= {.NX}
		for page := addr_round_down_to_page(seg.base); page < seg.end; page += shared.PAGE_SIZE {
			print.kensure(slot_available(dstPML4, page, ._4KB), "map_kernel_image: two segments share a page")
			map_page(dstPML4, page, page, ._4KB, flags, bootstrap)
		}
	}
}

pml4_share_kernel_half :: proc "contextless" (dstPML4: u64, entryRegionOnly: bool) {
	src := ([^]u64)(phys_to_ptr(kernelPML4))
	dst := ([^]u64)(phys_to_ptr(dstPML4))
	if entryRegionOnly {
		dst[ENTRY_REGION_PML4_INDEX] = src[ENTRY_REGION_PML4_INDEX]
		return
	}
	copy(dst[KERNEL_HALF_FIRST_PML4_INDEX:PT_ENTRIES], src[KERNEL_HALF_FIRST_PML4_INDEX:PT_ENTRIES])
}

entry_region_alloc :: proc(bytes: u64, guard: bool) -> u64 {
	print.kassert(bytes > 0 && bytes % shared.PAGE_SIZE == 0)
	if guard do entryRegionNext += shared.PAGE_SIZE
	start := entryRegionNext
	entryRegionNext += bytes
	print.kensure(entryRegionNext <= KERNEL_ENTRY_REGION_END, "entry_region_alloc: region exhausted")
	for offset := u64(0); offset < bytes; offset += shared.PAGE_SIZE {
		phys := alloc_zeroed(shared.PAGE_SIZE)
		print.kensure(phys != 0, "entry_region_alloc: out of memory")
		map_page(kernelPML4, phys, start + offset, ._4KB, {.Present, .Write, .NX} + kernelGlobalFlag)
	}
	return start
}

leaf_shift :: #force_inline proc "contextless" (size: lmem.PageSize) -> u64 {
	switch size {
	case ._4KB:
		return PT_SHIFT_PT
	case ._2MB:
		return PT_SHIFT_PD
	case ._1GB:
		return PT_SHIFT_PDPT
	}
	unreachable()
}

map_page :: proc "contextless" (
	pml4Phys: u64,
	phys, logical: u64,
	size: lmem.PageSize,
	flags: lmem.PageFlags,
	bootstrap := false,
) {
	pageBytes := lmem.page_bytes(size)
	print.kassert(phys % pageBytes == 0 && logical % pageBytes == 0)
	print.kassert(.PS not_in flags)
	print.kassert(size != ._1GB || pages1GB)
	lowerHalf := logical < KERNEL_DIRECT_MAP
	print.kassert(lowerHalf || .User not_in flags)

	table := ([^]u64)(phys_to_ptr(pml4Phys))
	leafShift := leaf_shift(size)
	for shift := PT_SHIFT_PML4; shift > leafShift; shift -= 9 {
		table = ensure_table(table, (logical >> shift) & PT_INDEX_MASK, lowerHalf, lowerHalf || .Write in flags, bootstrap)
	}
	idx := (logical >> leafShift) & PT_INDEX_MASK
	print.kassert(.Present not_in transmute(lmem.PageFlags)table[idx], "map_page: slot already mapped")
	leafFlags := flags + {.Present}
	if size != ._4KB do leafFlags += {.PS}
	table[idx] = phys | transmute(u64)leafFlags
}

unmap_page :: proc "contextless" (pml4Phys, logical: u64, size: lmem.PageSize) -> bool {
	table := ([^]u64)(phys_to_ptr(pml4Phys))
	leafShift := leaf_shift(size)
	for shift := PT_SHIFT_PML4; shift > leafShift; shift -= 9 {
		entry := table[(logical >> shift) & PT_INDEX_MASK]
		flags := transmute(lmem.PageFlags)entry
		if .Present not_in flags || .PS in flags do return false
		table = ([^]u64)(phys_to_ptr(entry & ENTRY_ADDR_MASK))
	}
	idx := (logical >> leafShift) & PT_INDEX_MASK
	leaf := transmute(lmem.PageFlags)table[idx]
	if .Present not_in leaf do return false
	print.kassert((.PS in leaf) == (size != ._4KB))
	table[idx] = 0
	return true
}

slot_available :: proc "contextless" (pml4Phys, logical: u64, size: lmem.PageSize) -> bool {
	slot := slot_entry(pml4Phys, logical, size)
	if slot == nil do return true
	flags := transmute(lmem.PageFlags)slot^
	if .Present not_in flags do return true
	if .PS in flags || size == ._4KB do return false
	return table_empty(slot^, table_level(size))
}

slot_claim :: proc(pml4Phys, logical: u64, size: lmem.PageSize, detached: ^[dynamic]u64) -> bool {
	if !slot_available(pml4Phys, logical, size) do return false
	slot := slot_entry(pml4Phys, logical, size)
	if slot == nil || .Present not_in transmute(lmem.PageFlags)slot^ do return true
	tables_collect(slot^, table_level(size), detached)
	slot^ = 0
	return true
}

@(private)
slot_entry :: proc "contextless" (pml4Phys, logical: u64, size: lmem.PageSize) -> ^u64 {
	table := ([^]u64)(phys_to_ptr(pml4Phys))
	leafShift := leaf_shift(size)
	for shift := PT_SHIFT_PML4; shift > leafShift; shift -= 9 {
		entry := table[(logical >> shift) & PT_INDEX_MASK]
		flags := transmute(lmem.PageFlags)entry
		if .Present not_in flags do return nil
		if .PS in flags do return &table[(logical >> shift) & PT_INDEX_MASK]
		table = ([^]u64)(phys_to_ptr(entry & ENTRY_ADDR_MASK))
	}
	return &table[(logical >> leafShift) & PT_INDEX_MASK]
}

@(private)
table_level :: proc "contextless" (size: lmem.PageSize) -> int {
	switch size {
	case ._4KB:
		return 0
	case ._2MB:
		return 1
	case ._1GB:
		return 2
	}
	unreachable()
}

@(private)
table_empty :: proc "contextless" (entry: u64, level: int) -> bool {
	print.kassert(level >= 1)
	table := ([^]u64)(phys_to_ptr(entry & ENTRY_ADDR_MASK))
	for child in table[:PT_ENTRIES] {
		flags := transmute(lmem.PageFlags)child
		if .Present not_in flags do continue
		if level == 1 || .PS in flags || !table_empty(child, level - 1) do return false
	}
	return true
}

@(private)
tables_collect :: proc(entry: u64, level: int, out: ^[dynamic]u64) {
	if level > 1 {
		table := ([^]u64)(phys_to_ptr(entry & ENTRY_ADDR_MASK))
		for child in table[:PT_ENTRIES] {
			if .Present in transmute(lmem.PageFlags)child do tables_collect(child, level - 1, out)
		}
	}
	append(out, entry & ENTRY_ADDR_MASK)
}

ensure_table :: #force_inline proc "contextless" (
	parent: [^]u64,
	index: u64,
	user, write, bootstrap: bool,
) -> [^]u64 {
	print.kassert(.PS not_in transmute(lmem.PageFlags)parent[index], "ensure_table: large-page mapping conflicts")
	if .Present not_in transmute(lmem.PageFlags)parent[index] {
		page := early_alloc_zeroed_page() if bootstrap else alloc_zeroed(shared.PAGE_SIZE)
		if page == 0 do panic_contextless("ensure_table: out of page-table memory")
		parent[index] = page | transmute(u64)lmem.PageFlags{.Present, .Write}
	}
	if user do parent[index] |= transmute(u64)lmem.PageFlags{.User}
	if write do parent[index] |= transmute(u64)lmem.PageFlags{.Write}
	return ([^]u64)(phys_to_ptr(parent[index] & ENTRY_ADDR_MASK))
}

@(private)
earlyAllocNextPage: u64

@(private)
early_alloc_zeroed_page :: proc "contextless" (limitPhys := max(u64)) -> u64 {
	limitPage := min(limitPhys / shared.PAGE_SIZE, state.totalPages)
	for i in earlyAllocNextPage ..< limitPage {
		if is_used(&state, i) do continue
		kset(&state, i)
		earlyAllocNextPage = i + 1
		phys := i * shared.PAGE_SIZE
		mem.zero(phys_to_ptr(phys), shared.PAGE_SIZE)
		return phys
	}
	return 0
}

enable_nxe :: proc() {
	EFER_MSR :: u32(0xC0000080)
	val := ah.rdmsr_asm(EFER_MSR)
	ah.wrmsr_asm(EFER_MSR, val | (1 << 11))
}
