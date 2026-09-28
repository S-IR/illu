package pmm

import "../../lib/lmem"
import "../../lib/shared"

pml4_destroy :: proc(pml4Phys: u64) {
	assert(pml4Phys != 0)
	assert(pml4Phys % shared.PAGE_SIZE == 0)
	assert(pml4Phys != kernelPML4, "pml4_destroy: attempted kernel PML4 free")

	pml4 := ([^]u64)(phys_to_ptr(pml4Phys))
	for entry in pml4[:KERNEL_HALF_FIRST_PML4_INDEX] {
		if .Present not_in transmute(lmem.PageFlags)entry do continue
		assert(.PS not_in transmute(lmem.PageFlags)entry, "pml4_destroy: invalid PML4 large page")
		destroy_table(entry, 3)
	}
	pfree(pml4Phys, shared.PAGE_SIZE)
}

@(private)
destroy_table :: proc(entry: u64, level: int) {
	assert(level >= 1 && level <= 3)
	tablePhys := entry & ENTRY_ADDR_MASK
	assert(tablePhys != 0)
	if level > 1 {
		table := ([^]u64)(phys_to_ptr(tablePhys))
		for child in table[:PT_ENTRIES] {
			flags := transmute(lmem.PageFlags)child
			if .Present in flags && .PS not_in flags do destroy_table(child, level - 1)
		}
	}
	pfree(tablePhys, shared.PAGE_SIZE)
}
