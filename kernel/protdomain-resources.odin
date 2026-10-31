package kernel
import "../lib/lmem"
import "../lib/spinlock"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "pmm"
user_copy_in_NO_LOCK :: proc "contextless" (
	domain: ^ProtectionDomain,
	dst: []$T,
	src: u64,
) -> bool {
	bytes := u64(len(dst) * size_of(T))
	if !user_mapped_range_accessible_NO_LOCK(domain, src, bytes, false) do return false
	mem.copy(raw_data(dst), pmm.phys_to_ptr(src), int(bytes))
	return true
}
user_copy_in :: proc "contextless" (domain: ^ProtectionDomain, dst: []$T, src: u64) -> bool {
	domain_read_lock(domain)
	return user_copy_in_NO_LOCK(domain, dst, src)
}
user_copy_out_NO_LOCK :: proc "contextless" (
	domain: ^ProtectionDomain,
	dst: u64,
	src: []$T,
) -> bool {
	bytes := u64(len(src) * size_of(T))
	if !user_mapped_range_accessible_NO_LOCK(domain, dst, bytes, true) do return false
	mem.copy(pmm.phys_to_ptr(dst), raw_data(src), int(bytes))
	return true
}

user_copy_out :: proc "contextless" (domain: ^ProtectionDomain, dst: u64, src: []$T) -> bool {
	domain_read_lock(domain)
	return user_copy_out_NO_LOCK(domain, dst, src)
}
USER_ADDR_END :: u64(1) << 47

page_size_usable :: proc "contextless" (size: lmem.PageSize) -> bool {
	switch size {
	case ._4KB, ._2MB:
		return true
	case ._1GB:
		return pmm.pages1GB
	}
	return false
}

mem_region_valid :: proc "contextless" (r: syscalls.MemRegion) -> bool {
	if r.size == 0 do return false
	if .PS in r.flags || .Global in r.flags do return false
	_, physOverflow := intrinsics.overflow_add(r.phys, r.size)
	if physOverflow do return false

	if .Present not_in r.flags do return .User not_in r.flags && r.logical == r.phys

	if !page_size_usable(r.pageSize) do return false
	logicalEnd, logicalOverflow := intrinsics.overflow_add(r.logical, r.size)
	if logicalOverflow || logicalEnd > USER_ADDR_END do return false
	pageBytes := lmem.page_bytes(r.pageSize)
	if r.phys % pageBytes != 0 || r.logical % pageBytes != 0 || r.size % pageBytes != 0 do return false
	cpuInfoBytes := cpu_infos_bytes(int(CpuInfos.cpuCount))
	return !resource_ranges_overlap(r.logical, r.size, userschedule.CPU_INFO_ADDR, cpuInfoBytes)
}

resources_backing_bytes :: proc "contextless" (resources: ^#soa[dynamic]MemoryResource) -> []u8 {
	FIELDS :: intrinsics.type_struct_field_count(MemoryResource)
	capacity := cap(resources^)
	if capacity == 0 do return nil
	columns := ([^]uintptr)(resources)[:FIELDS]
	for i in 1 ..< FIELDS do assert_contextless(columns[i] > columns[i - 1])
	info := runtime.type_info_base(type_info_of(MemoryResource)).variant.(runtime.Type_Info_Struct)
	end := columns[FIELDS - 1] + uintptr(capacity * info.types[FIELDS - 1].size)
	return ([^]u8)(rawptr(columns[0]))[:end - columns[0]]
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
user_mapped_range_accessible_NO_LOCK :: proc "contextless" (
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
		if .Present not_in resource.flags || .Volatile in resource.resourceFlags do return false
		if write && .Write not_in resource.flags do return false
		covered = resource.phys + resource.size
		idx += 1
	}
	return true
}
user_range_accessible_NO_LOCK :: proc "contextless" (
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
		if resource_contracted(resource) do return false
		if write && .Write not_in resource.flags do return false
		covered = resource.phys + resource.size
		idx += 1
	}
	return true
}
user_range_covered_NO_LOCK :: proc "contextless" (
	domain: ^ProtectionDomain,
	phys, size: u64,
	write: bool,
) -> (
	covered: u64,
) {
	if size == 0 || phys + size < phys do return 0
	end := phys + size
	for idx := max(resource_upper_bound(domain.resources[:], phys) - 1, 0);
	    idx < len(domain.resources) && domain.resources[idx].phys < end;
	    idx += 1 {
		resource := domain.resources[idx]
		if resource_contracted(resource) do continue
		if write && .Write not_in resource.flags do continue
		lo := max(phys, resource.phys)
		hi := min(end, resource.phys + resource.size)
		if hi > lo do covered += hi - lo
	}
	return covered
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
