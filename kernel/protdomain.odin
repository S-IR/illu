package kernel

import "../lib/spinlock"

ProtectionDomain :: struct {
	pml4:           u64,
	lock:           spinlock.RWLock,
	resources:      [dynamic]MemoryResource,
	executionCount: int,
}

resource_upper_bound :: proc "contextless" (resources: []MemoryResource, phys: u64) -> int {
	low, high := 0, len(resources)
	for low < high {
		mid := (low + high) / 2
		if resources[mid].phys <= phys {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

resource_find_exact :: proc "contextless" (resources: []MemoryResource, phys: u64) -> (ptr: ^MemoryResource, found: bool) {
	insertIdx := resource_upper_bound(resources, phys)
	if insertIdx == 0 do return nil, false

	candidate := &resources[insertIdx - 1]
	if candidate.phys != phys do return nil, false
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
	if phys < candidate.phys || phys >= candidate.phys + candidate.size do return nil, false
	return candidate, true
}

resource_ranges_overlap :: proc "contextless" (aPhys, aSize, bPhys, bSize: u64) -> bool {
	return aPhys < bPhys + bSize && bPhys < aPhys + aSize
}

resource_insert :: proc(
	resources: ^[dynamic]MemoryResource,
	resource: MemoryResource,
) -> (
	ptr: ^MemoryResource,
	inserted: bool,
) {
	if resource.size == 0 do return nil, false
	if resource.phys + resource.size < resource.phys do return nil, false

	insertIdx := resource_upper_bound(resources[:], resource.phys)
	if insertIdx > 0 {
		prev := resources[insertIdx - 1]
		if resource_ranges_overlap(resource.phys, resource.size, prev.phys, prev.size) do return nil, false
	}
	if insertIdx < len(resources) {
		next := resources[insertIdx]
		if resource_ranges_overlap(resource.phys, resource.size, next.phys, next.size) do return nil, false
	}

	inject_at(resources, insertIdx, resource)
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
	if candidate.phys != phys do return {}, false

	removed = candidate^
	ordered_remove(resources, insertIdx - 1)
	return removed, true
}
