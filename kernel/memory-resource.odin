package kernel
import "../lib/lmem"
import "../lib/shared"
import "../lib/syscalls"
import "core:mem"
import "pmm"


MemoryResourceFlag :: enum {
	Volatile,
	InterruptSource,
}

MemoryResourceFlags :: bit_set[MemoryResourceFlag;u64]

MemoryResource :: struct {
	phys:          u64,
	logical:       u64,
	size:          u64,
	flags:         lmem.PageFlags,
	rules:         []syscalls.MediatedRule,
	pageSize:      lmem.PageSize,
	resourceFlags: MemoryResourceFlags,
	underlay:      ^MemoryUnderlay,
}

resource_init :: proc(
	phys, size: u64,
	pageSize: lmem.PageSize,
	pageFlags: lmem.PageFlags,
	flags: MemoryResourceFlags,
	backend: MemorySlotBackend,
) -> MemoryResource {
	return MemoryResource {
		phys = phys,
		logical = phys,
		size = size,
		flags = pageFlags,
		pageSize = pageSize,
		resourceFlags = flags,
		underlay = memory_underlay_create(phys, size, backend),
	}
}

resource_granted :: proc(owner: MemoryResource, r: syscalls.MemRegion) -> MemoryResource {
	assert(r.phys >= owner.phys && r.phys + r.size <= owner.phys + owner.size)
	granted := owner
	granted.phys = r.phys
	granted.logical = r.logical
	granted.size = r.size
	granted.pageSize = r.pageSize
	granted.flags = r.flags
	return granted
}

region_mappable :: proc "contextless" (pml4: u64, r: syscalls.MemRegion) -> bool {
	for offset := u64(0); offset < r.size; offset += shared.PAGE_SIZE {
		leaf := pmm.leaf_entry(pml4, r.logical + offset)
		flags := transmute(lmem.PageFlags)leaf
		if .Present not_in flags do continue
		if .User in flags do return false
		if leaf & pmm.ENTRY_ADDR_MASK != r.phys + offset do return false
	}
	return true
}

region_flags_grantable :: proc "contextless" (want, have: lmem.PageFlags) -> bool {
	cacheBits :: lmem.PageFlags{.PWT, .PCD}
	if want & cacheBits != have & cacheBits do return false
	if .NX in have && .NX not_in want do return false
	return want - {.NX} <= have - {.NX}
}
