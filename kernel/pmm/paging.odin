package pmm
import ah "../../asm_helpers"
import "../../lib/elf"
import "../../lib/shared"
import "../../uefi"
import "../print"
import "core:mem"
PageFlag :: enum u64 {
	Present = 0,
	Write   = 1,
	User    = 2,
	PWT     = 3,
	PCD     = 4,
	PS      = 7,
	NX      = 63,
}
PageFlags :: bit_set[PageFlag;u64]
#assert(size_of(PageFlags) == size_of(u64))

PAGE_RX :: PageFlags{.Present, .User}
PAGE_RW :: PageFlags{.Present, .User, .Write, .NX}
PAGE_R :: PageFlags{.Present, .User, .NX}
PAGE_MMIO :: PageFlags{.Present, .Write, .PWT, .PCD}

kernelPML4: u64

paging_init :: proc(
	kernelImg: elf.Image,
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapSize: u64,
	memoryMapDescSize: u64,
) {
	enable_nxe()
	// APs load CR3 before long mode is fully established, so the top-level page
	// table must live below 4 GiB.
	kernelPML4 = pmm_alloc_zeroed_page_below(u64(4) * u64(mem.Gigabyte))
	print.kensure(kernelPML4 != 0, "paging_init: no page below 4 GiB for kernel PML4")
	print.kensure(kernelPML4 < u64(4) * u64(mem.Gigabyte), "paging_init: kernel PML4 above 4 GiB")

	for p in u64(1) ..< state.totalPages {
		map_page(kernelPML4, p * shared.PAGE_SIZE, ._4KB, PAGE_RW)
	}

	for seg in kernelImg.segments {
		flags := PageFlags{.Present, .NX}
		if .W in seg.perms do flags += {.Write}
		if .X in seg.perms do flags -= {.NX}
		phys := addr_round_down_to_page(seg.base)
		end := addr_round_up_to_page(seg.end)
		for phys < end {
			map_page(kernelPML4, phys, ._4KB, flags); phys += shared.PAGE_SIZE
		}
	}

	GB := u64(mem.Gigabyte)
	MB2 := u64(2 * mem.Megabyte)
	for p in u64(1) ..< state.totalPages {
		phys := p * shared.PAGE_SIZE
		if phys % MB2 == 0 &&
		   state.totalPages - p >= MB2 / shared.PAGE_SIZE &&
		   block_is_free(phys, MB2) {
			map_page(kernelPML4, phys, ._2MB, PAGE_RW)
		}
		if cpuid_has_1gb_pages() &&
		   phys % GB == 0 &&
		   state.totalPages - p >= GB / shared.PAGE_SIZE &&
		   block_is_free(phys, GB) {
			map_page(kernelPML4, phys, ._1GB, PAGE_RW)
		}
	}
	map_page(kernelPML4, trampolinePhys, ._4KB, {.Present, .Write})
	ah.write_cr3(kernelPML4)
}
cpuid_has_1gb_pages :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.EXTENDED_FEATURE_INFO, 0, &r)
	return (r.edx >> 26) & 1 == 1
}
@(private)
block_is_free :: proc(start: u64, size: u64) -> bool {
	start_page := start / shared.PAGE_SIZE
	end_page := (start + size) / shared.PAGE_SIZE
	for p in start_page ..< end_page {
		if p < state.totalPages && is_used(&state, p) {
			return false
		}
	}
	return true
}
PageSize :: enum {
	_4KB,
	_2MB,
	_1GB,
}
PT_SHIFT_PML4 :: u64(39)
PT_SHIFT_PDPT :: u64(30)
PT_SHIFT_PD :: u64(21)
PT_SHIFT_PT :: u64(12)
PT_INDEX_MASK :: u64(0x1FF)
ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)

split_1gb :: proc(pdpt: [^]u64, idx: u64) {
	existing := transmute(PageFlags)pdpt[idx]
	if .Present not_in existing || .PS not_in existing do return
	oldPhys := pdpt[idx] & ENTRY_ADDR_MASK
	oldFlags := existing - {.PS}
	newTable := pmm_alloc_zeroed_page()
	pt := ([^]u64)(uintptr(newTable))
	for i in u64(0) ..< 512 {
		pt[i] = (oldPhys + i * u64(2 * mem.Megabyte)) | transmute(u64)(oldFlags + {.Present, .PS})
	}
	pdpt[idx] = newTable | transmute(u64)(PageFlags{.Present, .Write})
}

split_2mb :: proc(pd: [^]u64, idx: u64) {
	existing := transmute(PageFlags)pd[idx]
	if .Present not_in existing || .PS not_in existing do return
	oldPhys := pd[idx] & ENTRY_ADDR_MASK
	oldFlags := existing - {.PS}
	newTable := pmm_alloc_zeroed_page()
	pt := ([^]u64)(uintptr(newTable))
	for i in u64(0) ..< 512 {
		pt[i] = (oldPhys + i * shared.PAGE_SIZE) | transmute(u64)(oldFlags + {.Present})
	}
	pd[idx] = newTable | transmute(u64)(PageFlags{.Present, .Write})
}

map_page :: proc(pml4Idx: u64, phys: u64, size: PageSize, flags: PageFlags) {
	assert(phys % shared.PAGE_SIZE == 0)
	user := .User in flags
	pml4eIdx := (phys >> PT_SHIFT_PML4) & PT_INDEX_MASK
	pdpteIdx := (phys >> PT_SHIFT_PDPT) & PT_INDEX_MASK
	pdeIdx := (phys >> PT_SHIFT_PD) & PT_INDEX_MASK
	pteIdx := (phys >> PT_SHIFT_PT) & PT_INDEX_MASK

	pml4 := ([^]u64)(uintptr(pml4Idx))

	if size == ._1GB {
		pdpt := ensure_table(pml4, pml4eIdx, user)
		pdpt[pdpteIdx] = phys | transmute(u64)(flags + {.Present, .PS})
		return
	}

	pdpt := ensure_table(pml4, pml4eIdx, user)
	split_1gb(pdpt, pdpteIdx)

	if size == ._2MB {
		pd := ensure_table(pdpt, pdpteIdx, user)
		split_2mb(pd, pdeIdx)
		pd[pdeIdx] = phys | transmute(u64)(flags + {.Present, .PS})
		return
	}

	pd := ensure_table(pdpt, pdpteIdx, user)
	split_2mb(pd, pdeIdx)
	pt := ensure_table(pd, pdeIdx, user)
	pt[pteIdx] = phys | transmute(u64)(flags + {.Present})
}

ensure_table :: #force_inline proc(parent: [^]u64, index: u64, user := false) -> [^]u64 {
	if .Present not_in transmute(PageFlags)parent[index] {
		parent[index] = pmm_alloc_zeroed_page() | transmute(u64)(PageFlags{.Present, .Write})
	}
	if user {
		parent[index] |= transmute(u64)(PageFlags{.User})
	}
	return ([^]u64)(uintptr(parent[index] & ENTRY_ADDR_MASK))
}
ENTRY_ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)

pmm_alloc_zeroed_page :: proc() -> u64 {
	for i in u64(0) ..< state.totalPages {
		if !is_used(&state, i) {
			kset(&state, i)
			phys := i * shared.PAGE_SIZE
			mem.zero(rawptr(uintptr(phys)), shared.PAGE_SIZE)
			return phys
		}
	}

	return 0
}

pmm_alloc_zeroed_page_below :: proc(limitPhys: u64) -> u64 {
	limitPage := limitPhys / shared.PAGE_SIZE
	if limitPage > state.totalPages do limitPage = state.totalPages
	for i in u64(0) ..< limitPage {
		if !is_used(&state, i) {
			kset(&state, i)
			phys := i * shared.PAGE_SIZE
			mem.zero(rawptr(uintptr(phys)), shared.PAGE_SIZE)
			return phys
		}
	}
	return 0
}

enable_nxe :: proc() {
	EFER_MSR :: u32(0xC0000080)
	val := ah.rdmsr_asm(EFER_MSR)
	ah.wrmsr_asm(EFER_MSR, val | (1 << 11))
}
