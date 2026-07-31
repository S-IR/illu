package pmm

import "../../lib/shared"

pml4_deep_copy :: proc(dstPML4Phys, srcPML4Phys: u64, removeUserBit := true) {
	assert(srcPML4Phys != 0)
	assert(dstPML4Phys != 0)
	assert(dstPML4Phys != srcPML4Phys)

	srcPML4 := ([^]u64)(uintptr(srcPML4Phys))
	dstPML4 := ([^]u64)(uintptr(dstPML4Phys))

	for i in 0 ..< 512 {
		entry := srcPML4[i]
		if .Present not_in transmute(PageFlags)entry do continue
		dstPML4[i] = copy_pdpt(entry, removeUserBit)
	}
}

@(private)
copy_pdpt :: proc(pml4e: u64, removeUserBit: bool) -> u64 {
	flags := transmute(PageFlags)pml4e
	if .Present not_in flags do return 0

	newPdptPhys := pmm_alloc_zeroed_page()
	src := ([^]u64)(uintptr(pml4e & ENTRY_ADDR_MASK))
	dst := ([^]u64)(uintptr(newPdptPhys))

	for i in 0 ..< 512 {
		entry := src[i]
		flags := transmute(PageFlags)entry
		if .Present not_in flags do continue

		if .PS in flags {
			dst[i] = maybe_strip_user(entry, removeUserBit)
		} else {
			dst[i] = copy_pd(entry, removeUserBit)
		}
	}
	return newPdptPhys | transmute(u64)(PageFlags{.Present, .Write})
}

@(private)
copy_pd :: proc(pdpte: u64, removeUserBit: bool) -> u64 {
	flags := transmute(PageFlags)pdpte
	if .Present not_in flags do return 0

	newPdPhys := pmm_alloc_zeroed_page()
	src := ([^]u64)(uintptr(pdpte & ENTRY_ADDR_MASK))
	dst := ([^]u64)(uintptr(newPdPhys))

	for i in 0 ..< 512 {
		entry := src[i]
		flags := transmute(PageFlags)entry
		if .Present not_in flags do continue

		if .PS in flags {
			dst[i] = maybe_strip_user(entry, removeUserBit)
		} else {
			dst[i] = copy_pt(entry, removeUserBit)
		}
	}
	return newPdPhys | transmute(u64)(PageFlags{.Present, .Write})
}

@(private)
copy_pt :: proc(pde: u64, removeUserBit: bool) -> u64 {
	flags := transmute(PageFlags)pde
	if .Present not_in flags do return 0

	newPtPhys := pmm_alloc_zeroed_page()
	src := ([^]u64)(uintptr(pde & ENTRY_ADDR_MASK))
	dst := ([^]u64)(uintptr(newPtPhys))

	for i in 0 ..< 512 {
		entry := src[i]
		flags := transmute(PageFlags)entry
		if .Present not_in flags do continue
		dst[i] = maybe_strip_user(entry, removeUserBit)
	}
	return newPtPhys | transmute(u64)(PageFlags{.Present, .Write})
}

@(private)
maybe_strip_user :: #force_inline proc(entry: u64, remove: bool) -> u64 {
	if remove {
		return entry & ~transmute(u64)PageFlags{.User}
	}
	return entry
}
