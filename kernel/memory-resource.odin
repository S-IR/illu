package kernel
import "../lib/lmem"
import "../lib/shared"
import "../lib/syscalls"
import "pmm"
import "print"


MemoryResourceFlag :: enum {
	Volatile,
	InterruptSource,
}

MemoryResourceFlags :: bit_set[MemoryResourceFlag;u8]

MemoryResource :: struct {
	phys:          u64,
	logical:       u64,
	size:          u64,
	flags:         lmem.PageFlags,
	pageSize:      lmem.PageSize,
	resourceFlags: MemoryResourceFlags,
	contract:      ^ContractRules,
	underlay:      ^MemoryUnderlay,
}
#assert(size_of(MemoryResource) <= 64)

ContractRules :: struct {
	r, w: []syscalls.ContractRule,
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
	assert(!resource_contracted(owner))
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
	pageBytes := lmem.page_bytes(r.pageSize)
	for offset := u64(0); offset < r.size; offset += pageBytes {
		if !pmm.slot_available(pml4, r.logical + offset, r.pageSize) do return false
	}
	return true
}

resource_map :: proc(pml4: u64, r: MemoryResource, detached: ^[dynamic]u64) {
	pageBytes := lmem.page_bytes(r.pageSize)
	for offset := u64(0); offset < r.size; offset += pageBytes {
		claimed := pmm.slot_claim(pml4, r.logical + offset, r.pageSize, detached)
		print.kassert(claimed)
		pmm.map_page(pml4, r.phys + offset, r.logical + offset, r.pageSize, r.flags)
	}
}

detached_tables_free :: proc(detached: ^[dynamic]u64) {
	for table in detached do pmm.free_pages(table, shared.PAGE_SIZE)
	delete(detached^)
	detached^ = nil
}

resource_unmap :: proc "contextless" (pml4: u64, r: MemoryResource) {
	pageBytes := lmem.page_bytes(r.pageSize)
	for offset := u64(0); offset < r.size; offset += pageBytes {
		unmapped := pmm.unmap_page(pml4, r.logical + offset, r.pageSize)
		print.kassert(unmapped)
	}
}

region_flags_grantable :: proc "contextless" (want, have: lmem.PageFlags) -> bool {
	cacheBits :: lmem.PageFlags{.PWT, .PCD}
	if want & cacheBits != have & cacheBits do return false
	if .NX in have && .NX not_in want do return false
	return want - {.NX} <= have - {.NX}
}

resource_contracted :: proc "contextless" (r: MemoryResource) -> bool {
	return r.contract != nil
}
