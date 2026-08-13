package pmm

import "../../lib/lmem"
import "../../lib/shared"

pml4_deep_copy :: proc(dstPML4Phys, srcPML4Phys: u64, removeUserBit := true) {
	assert(srcPML4Phys != 0)
	assert(dstPML4Phys != 0)
	assert(dstPML4Phys != srcPML4Phys)
	assert(srcPML4Phys % shared.PAGE_SIZE == 0)
	assert(dstPML4Phys % shared.PAGE_SIZE == 0)

	srcPML4 := ([^]u64)(uintptr(srcPML4Phys))
	dstPML4 := ([^]u64)(uintptr(dstPML4Phys))

	for i in 0 ..< 512 {
		entry := srcPML4[i]
		if .Present not_in transmute(lmem.PageFlags)entry do continue
		dstPML4[i] = copy_pdpt(entry, removeUserBit)
	}
}

pml4_destroy :: proc(pml4Phys: u64) {
	assert(pml4Phys != 0)
	assert(pml4Phys % shared.PAGE_SIZE == 0)
	assert(pml4Phys != kernelPML4, "pml4_destroy: attempted kernel PML4 free")

	pml4 := ([^]u64)(uintptr(pml4Phys))
	for i in 0 ..< 512 {
		entry := pml4[i]
		if .Present not_in transmute(lmem.PageFlags)entry do continue
		assert(.PS not_in transmute(lmem.PageFlags)entry, "pml4_destroy: invalid PML4 large page")
		destroy_pdpt(entry)
	}
	pfree(pml4Phys, shared.PAGE_SIZE)
}

@(private)
destroy_pdpt :: proc(pdpte: u64) {
	assert(pdpte != 0)
	assert(.PS not_in transmute(lmem.PageFlags)pdpte)
	pdptPhys := pdpte & ENTRY_ADDR_MASK
	assert(pdptPhys != 0)
	pdpt := ([^]u64)(uintptr(pdptPhys))
	for i in 0 ..< 512 {
		entry := pdpt[i]
		if .Present not_in transmute(lmem.PageFlags)entry do continue
		if .PS in transmute(lmem.PageFlags)entry do continue
		destroy_pd(entry)
	}
	pfree(pdptPhys, shared.PAGE_SIZE)
}

@(private)
destroy_pd :: proc(pde: u64) {
	assert(pde != 0)
	assert(.PS not_in transmute(lmem.PageFlags)pde)
	pdPhys := pde & ENTRY_ADDR_MASK
	assert(pdPhys != 0)
	pd := ([^]u64)(uintptr(pdPhys))
	for i in 0 ..< 512 {
		entry := pd[i]
		if .Present not_in transmute(lmem.PageFlags)entry do continue
		if .PS in transmute(lmem.PageFlags)entry do continue
		destroy_pt(entry)
	}
	pfree(pdPhys, shared.PAGE_SIZE)
}

@(private)
destroy_pt :: proc(pte: u64) {
	assert(pte != 0)
	assert(.PS not_in transmute(lmem.PageFlags)pte)
	ptPhys := pte & ENTRY_ADDR_MASK
	assert(ptPhys != 0)
	pfree(ptPhys, shared.PAGE_SIZE)
}

@(private)
copy_pdpt :: proc(pml4e: u64, removeUserBit: bool) -> u64 {
	flags := transmute(lmem.PageFlags)pml4e
	if .Present not_in flags do return 0

	newPdptPhys := alloc_zeroed(shared.PAGE_SIZE)
	assert(newPdptPhys != 0, "copy_pdpt: out of page-table memory")
	src := ([^]u64)(uintptr(pml4e & ENTRY_ADDR_MASK))
	dst := ([^]u64)(uintptr(newPdptPhys))

	for i in 0 ..< 512 {
		entry := src[i]
		ptFlags := transmute(lmem.PageFlags)entry
		if .Present not_in ptFlags do continue

		if .PS in ptFlags {
			dst[i] = maybe_strip_user(entry, removeUserBit)
		} else {
			dst[i] = copy_pd(entry, removeUserBit)
		}
	}
	return newPdptPhys | transmute(u64)(lmem.PageFlags{.Present, .Write})
}

@(private)
copy_pd :: proc(pdpte: u64, removeUserBit: bool) -> u64 {
	flags := transmute(lmem.PageFlags)pdpte
	if .Present not_in flags do return 0

	newPdPhys := alloc_zeroed(shared.PAGE_SIZE)
	assert(newPdPhys != 0, "copy_pd: out of page-table memory")
	src := ([^]u64)(uintptr(pdpte & ENTRY_ADDR_MASK))
	dst := ([^]u64)(uintptr(newPdPhys))

	for i in 0 ..< 512 {
		entry := src[i]
		pdFlags := transmute(lmem.PageFlags)entry
		if .Present not_in pdFlags do continue

		if .PS in pdFlags {
			dst[i] = maybe_strip_user(entry, removeUserBit)
		} else {
			dst[i] = copy_pt(entry, removeUserBit)
		}
	}
	return newPdPhys | transmute(u64)(lmem.PageFlags{.Present, .Write})
}

@(private)
copy_pt :: proc(pde: u64, removeUserBit: bool) -> u64 {
	flags := transmute(lmem.PageFlags)pde
	if .Present not_in flags do return 0

	newPtPhys := alloc_zeroed(shared.PAGE_SIZE)
	assert(newPtPhys != 0, "copy_pt: out of page-table memory")
	src := ([^]u64)(uintptr(pde & ENTRY_ADDR_MASK))
	dst := ([^]u64)(uintptr(newPtPhys))

	for i in 0 ..< 512 {
		entry := src[i]
		physFlags := transmute(lmem.PageFlags)entry
		if .Present not_in physFlags do continue
		dst[i] = maybe_strip_user(entry, removeUserBit)
	}
	return newPtPhys | transmute(u64)(lmem.PageFlags{.Present, .Write})
}

@(private)
maybe_strip_user :: #force_inline proc(entry: u64, remove: bool) -> u64 {
	if remove {
		return entry & ~transmute(u64)lmem.PageFlags{.User}
	}
	return entry
}
