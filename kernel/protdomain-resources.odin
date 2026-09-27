package kernel
import "../lib/lmem"
import "../lib/shared"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "pmm"

USER_ADDR_END :: u64(1) << 47

mem_region_valid :: proc "contextless" (r: syscalls.MemRegion) -> bool {
	if r.pageSize != ._4KB || r.size == 0 do return false
	pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
	if r.phys % pageBytes != 0 || r.logical % pageBytes != 0 || r.size % pageBytes != 0 do return false
	_, physOverflow := intrinsics.overflow_add(r.phys, r.size)
	logicalEnd, logicalOverflow := intrinsics.overflow_add(r.logical, r.size)
	if physOverflow || logicalOverflow || logicalEnd > USER_ADDR_END do return false
	cpuInfoBytes := cpu_infos_bytes(int(CpuInfos.cpuCount))
	return !resource_ranges_overlap(r.logical, r.size, userschedule.CPU_INFO_ADDR, cpuInfoBytes)
}

region_covers_kernel :: proc "contextless" (pml4: u64, r: syscalls.MemRegion) -> bool {
	for offset := u64(0); offset < r.size; offset += shared.PAGE_SIZE {
		leaf := pmm.leaf_entry(pml4, r.logical + offset)
		flags := transmute(lmem.PageFlags)leaf
		if .Present not_in flags || .User in flags do continue
		if leaf & pmm.ENTRY_ADDR_MASK != r.phys + offset do return true
	}
	return false
}


resource_upper_bound :: proc "contextless" (resources: #soa[]MemoryResource, phys: u64) -> int {
	low, high := 0, len(resources)
	for low < high {
		mid := (low + high) / 2
		if resources.phys[mid] <= phys {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}


resource_find_exact :: proc "contextless" (
	resources: #soa[]MemoryResource,
	phys: u64,
) -> (
	idx: int,
	found: bool,
) {
	idx = resource_upper_bound(resources, phys) - 1
	if idx < 0 || resources.phys[idx] != phys do return -1, false
	return idx, true
}

resource_find_containing :: proc "contextless" (
	resources: #soa[]MemoryResource,
	phys: u64,
) -> (
	idx: int,
	found: bool,
) {
	idx = resource_upper_bound(resources, phys) - 1
	if idx < 0 || phys - resources.phys[idx] >= resources.size[idx] do return -1, false
	return idx, true
}

// Callers dereference phys directly. Without meltdown isolation that happens on the
// domain's page tables, so a domain's own logical mapping at phys can redirect the
// access. Safe: domains can only map memory they own, so it only hits itself.
user_range_accessible :: proc "contextless" (
	domain: ^ProtectionDomain,
	phys, size: u64,
	write: bool,
) -> bool {
	if size == 0 || phys + size < phys do return false
	end := phys + size
	covered := phys
	idx := resource_upper_bound(domain.resources[:], phys) - 1
	for covered < end {
		if idx < 0 || idx >= len(domain.resources) do return false
		resource := domain.resources[idx]
		if covered < resource.phys || covered >= resource.phys + resource.size do return false
		if write && .Write not_in resource.flags do return false
		covered = resource.phys + resource.size
		idx += 1
	}
	return true
}

resource_ranges_overlap :: proc "contextless" (aPhys, aSize, bPhys, bSize: u64) -> bool {
	return aPhys < bPhys + bSize && bPhys < aPhys + aSize
}

// Whether [phys, phys+size) would collide with anything already tracked.
// Shared by resource_insert and by callers that need to check without
// mutating anything.
resource_overlaps :: proc "contextless" (
	resources: #soa[]MemoryResource,
	phys, size: u64,
) -> bool {
	idx := resource_upper_bound(resources, phys)
	if idx > 0 && resource_ranges_overlap(phys, size, resources.phys[idx - 1], resources.size[idx - 1]) do return true
	if idx < len(resources) && resource_ranges_overlap(phys, size, resources.phys[idx], resources.size[idx]) do return true
	return false
}

resource_insert :: proc(
	resources: ^#soa[dynamic]MemoryResource,
	resource: MemoryResource,
) -> (
	idx: int,
	inserted: bool,
) {
	if resource.size == 0 do return -1, false
	if resource.phys + resource.size < resource.phys do return -1, false
	if resource_overlaps(resources[:], resource.phys, resource.size) do return -1, false
	idx = resource_upper_bound(resources[:], resource.phys)
	injected, err := inject_at_elem_soa(resources, idx, resource)
	if err != nil do return -1, false
	assert(injected)
	return idx, true
}

resource_remove :: proc(
	resources: ^#soa[dynamic]MemoryResource,
	phys: u64,
) -> (
	removed: MemoryResource,
	found: bool,
) {
	idx, exact := resource_find_exact(resources[:], phys)
	if !exact do return {}, false
	removed = resources[idx]
	ordered_remove_soa(resources, idx)
	return removed, true
}
