package pmm
import ah "../../asm_helpers"
import "../../lib/elf"
import "../../lib/lmem"
import "../../lib/shared"
import "../../uefi"
import "../print"
import "core:mem"


PAGE_RX :: lmem.PageFlags{.Present, .User}
PAGE_RW :: lmem.PageFlags{.Present, .User, .Write, .NX}
PAGE_R :: lmem.PageFlags{.Present, .User, .NX}
PAGE_MMIO :: lmem.PageFlags{.Present, .Write, .PWT, .PCD}

@(export, link_name = "kernelPML4")
kernelPML4: u64

paging_init :: proc(
	kernelImg: elf.Image,
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapSize: u64,
	memoryMapDescSize: u64,
) {
	enable_nxe()
	kernelPML4 = pmm_alloc_zeroed_page_below(u64(4) * u64(mem.Gigabyte))
	print.kensure(kernelPML4 != 0, "paging_init: no page below 4 GiB for kernel PML4")
	print.kensure(kernelPML4 < u64(4) * u64(mem.Gigabyte), "paging_init: kernel PML4 above 4 GiB")

	for p in u64(1) ..< state.totalPages {
		map_page(kernelPML4, p * shared.PAGE_SIZE, ._4KB, PAGE_RW, true)
	}

	for seg in kernelImg.segments {
		flags := lmem.PageFlags{.Present, .NX}
		if .W in seg.perms do flags += {.Write}
		if .X in seg.perms do flags -= {.NX}
		phys := addr_round_down_to_page(seg.base)
		end := addr_round_up_to_page(seg.end)
		for phys < end {
			map_page(kernelPML4, phys, ._4KB, flags, true); phys += shared.PAGE_SIZE
		}
	}

	map_page(kernelPML4, trampolinePhys, ._4KB, {.Present, .Write}, true)
	ah.write_cr3(kernelPML4)
}

PT_SHIFT_PML4 :: u64(39)
PT_SHIFT_PDPT :: u64(30)
PT_SHIFT_PD :: u64(21)
PT_SHIFT_PT :: u64(12)
PT_INDEX_MASK :: u64(0x1FF)
ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)

map_page :: proc "contextless" (
	pml4Idx: u64,
	phys: u64,
	size: lmem.PageSize,
	flags: lmem.PageFlags,
	bootstrap := false,
) {
	print.kassert(phys % shared.PAGE_SIZE == 0)
	if size == ._2MB do print.kassert(phys % u64(2 * mem.Megabyte) == 0)
	if size == ._1GB do print.kassert(phys % u64(mem.Gigabyte) == 0)
	user := .User in flags
	pml4eIdx := (phys >> PT_SHIFT_PML4) & PT_INDEX_MASK
	pdpteIdx := (phys >> PT_SHIFT_PDPT) & PT_INDEX_MASK
	pdeIdx := (phys >> PT_SHIFT_PD) & PT_INDEX_MASK
	pteIdx := (phys >> PT_SHIFT_PT) & PT_INDEX_MASK

	pml4 := ([^]u64)(uintptr(pml4Idx))

	if size == ._1GB {
		pdpt := ensure_table(pml4, pml4eIdx, user, bootstrap)
		print.kassert(
			.Present not_in transmute(lmem.PageFlags)pdpt[pdpteIdx],
			"map_page: 1 GiB mapping conflicts",
		)
		pdpt[pdpteIdx] = phys | transmute(u64)(flags + {.Present, .PS})
		return
	}

	pdpt := ensure_table(pml4, pml4eIdx, user, bootstrap)

	if size == ._2MB {
		pd := ensure_table(pdpt, pdpteIdx, user, bootstrap)
		print.kassert(
			.Present not_in transmute(lmem.PageFlags)pd[pdeIdx],
			"map_page: 2 MiB mapping conflicts",
		)
		pd[pdeIdx] = phys | transmute(u64)(flags + {.Present, .PS})
		return
	}

	pd := ensure_table(pdpt, pdpteIdx, user, bootstrap)
	pt := ensure_table(pd, pdeIdx, user, bootstrap)
	pt[pteIdx] = phys | transmute(u64)(flags + {.Present})
}

ensure_table :: #force_inline proc "contextless" (
	parent: [^]u64,
	index: u64,
	user := false,
	bootstrap := false,
) -> [^]u64 {
	print.kassert(
		.PS not_in transmute(lmem.PageFlags)parent[index],
		"ensure_table: large-page mapping conflicts",
	)
	if .Present not_in transmute(lmem.PageFlags)parent[index] {
		page := u64(0)
		if bootstrap {
			page = early_alloc_zeroed_page()
		} else {
			page = alloc_zeroed(shared.PAGE_SIZE)
		}
		print.kassert(page != 0, "ensure_table: out of page-table memory")
		parent[index] = page | transmute(u64)(lmem.PageFlags{.Present, .Write})
	}
	if user {
		parent[index] |= transmute(u64)(lmem.PageFlags{.User})
	}
	return ([^]u64)(uintptr(parent[index] & ENTRY_ADDR_MASK))
}
ENTRY_ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)


@(private)
early_alloc_zeroed_page :: proc "contextless" () -> u64 {
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

@(private)
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
