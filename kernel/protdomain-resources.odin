package kernel
import "../lib/lmem"
import "../lib/syscalls"
import "base:intrinsics"

USER_ADDR_END :: u64(1) << 47

mem_region_valid :: proc "contextless" (r: syscalls.MemRegion) -> bool {
	pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
	if pageBytes == 0 || r.size == 0 do return false
	if r.phys % pageBytes != 0 || r.logical % pageBytes != 0 || r.size % pageBytes != 0 do return false
	_, physOverflow := intrinsics.overflow_add(r.phys, r.size)
	logicalEnd, logicalOverflow := intrinsics.overflow_add(r.logical, r.size)
	return !physOverflow && !logicalOverflow && logicalEnd <= USER_ADDR_END
}

region_flags_grantable :: proc "contextless" (want, have: lmem.PageFlags) -> bool {
	if .NX in have && .NX not_in want do return false
	return want - {.NX} <= have - {.NX}
}

resource_upper_bound :: proc "contextless" (resources: []MemoryResource, phys: u64) -> int {
	low, high := 0, len(resources)
	for low < high {
		mid := (low + high) / 2
		if resources[mid].overlay.phys <= phys {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

resource_find_exact :: proc "contextless" (
	resources: []MemoryResource,
	phys: u64,
) -> (
	ptr: ^MemoryResource,
	found: bool,
) {
	insertIdx := resource_upper_bound(resources, phys)
	if insertIdx == 0 do return nil, false

	candidate := &resources[insertIdx - 1]
	if candidate.overlay.phys != phys do return nil, false
	return candidate, true
}

resource_find_containing :: proc "contextless" (
	resources: []MemoryResource,
	phys: u64,
) -> (
	ptr: ^MemoryResource,
	found: bool,
) {
	insertIdx := resource_upper_bound(resources, phys)
	if insertIdx == 0 do return nil, false

	candidate := &resources[insertIdx - 1]
	if phys < candidate.overlay.phys || phys >= candidate.overlay.phys + candidate.overlay.size do return nil, false
	return candidate, true
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
		overlay := domain.resources[idx].overlay
		if covered < overlay.phys || covered >= overlay.phys + overlay.size do return false
		if write && .Write not_in overlay.flags do return false
		covered = overlay.phys + overlay.size
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
resource_overlaps :: proc "contextless" (resources: []MemoryResource, phys, size: u64) -> bool {
	insertIdx := resource_upper_bound(resources, phys)
	if insertIdx > 0 {
		prev := resources[insertIdx - 1]
		if resource_ranges_overlap(phys, size, prev.overlay.phys, prev.overlay.size) do return true
	}
	if insertIdx < len(resources) {
		next := resources[insertIdx]
		if resource_ranges_overlap(phys, size, next.overlay.phys, next.overlay.size) do return true
	}
	return false
}

resource_insert :: proc(
	resources: ^[dynamic]MemoryResource,
	resource: MemoryResource,
) -> (
	ptr: ^MemoryResource,
	inserted: bool,
) {
	if resource.overlay.size == 0 do return nil, false
	if resource.overlay.phys + resource.overlay.size < resource.overlay.phys do return nil, false
	if resource_overlaps(resources[:], resource.overlay.phys, resource.overlay.size) do return nil, false

	insertIdx := resource_upper_bound(resources[:], resource.overlay.phys)
	_, aErr := inject_at(resources, insertIdx, resource)
	if aErr != nil do return nil, false
	return &resources[insertIdx], true
}

resource_remove :: proc(
	resources: ^[dynamic]MemoryResource,
	phys: u64,
) -> (
	removed: MemoryResource,
	found: bool,
) {
	insertIdx := resource_upper_bound(resources[:], phys)
	if insertIdx == 0 do return {}, false

	candidate := &resources[insertIdx - 1]
	if candidate.overlay.phys != phys do return {}, false

	removed = candidate^
	ordered_remove(resources, insertIdx - 1)
	return removed, true
}
