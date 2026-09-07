package kernel

import "../lib/spinlock"
import "print"

ProtectionDomain :: struct {
	pml4:           u64,
	lock:           spinlock.RWLock,
	resources:      [dynamic]MemoryResource,
	executionCount: int,
	slotIdx:        int,
}

// Registry of all live protection domains, so they can be enumerated later
// (e.g. for accounting or debugging). Slots are reused in place: removing a
// domain nils its slot and pushes the index onto freeSlots instead of
// shifting the array, so a domain's slotIdx stays valid for its lifetime.
currentProtDomains := struct {
	lock:      spinlock.Spinlock,
	prots:     [dynamic]^ProtectionDomain,
	freeSlots: [dynamic]int,
}{}

PROT_DOMAIN_ARRAY_START_CAP :: 8

protdomain_register :: proc(pd: ^ProtectionDomain) {
	print.kassert(pd != nil, "protdomain_register: nil domain")
	if pd == nil do return

	spinlock.lock(&currentProtDomains.lock)
	defer spinlock.unlock(&currentProtDomains.lock)

	if currentProtDomains.prots == nil {
		currentProtDomains.prots = make([dynamic]^ProtectionDomain, 0, PROT_DOMAIN_ARRAY_START_CAP)
	}

	if len(currentProtDomains.freeSlots) > 0 {
		idx := pop(&currentProtDomains.freeSlots)
		currentProtDomains.prots[idx] = pd
		pd.slotIdx = idx
	} else {
		append(&currentProtDomains.prots, pd)
		pd.slotIdx = len(currentProtDomains.prots) - 1
	}
}

protdomain_unregister :: proc(pd: ^ProtectionDomain) {
	print.kassert(pd != nil, "protdomain_unregister: nil domain")
	if pd == nil do return

	spinlock.lock(&currentProtDomains.lock)
	defer spinlock.unlock(&currentProtDomains.lock)

	print.kassert(currentProtDomains.prots != nil, "protdomain_unregister: registry empty")
	print.kassert(pd.slotIdx >= 0 && pd.slotIdx < len(currentProtDomains.prots), "protdomain_unregister: bad slotIdx")
	print.kassert(currentProtDomains.prots[pd.slotIdx] == pd, "protdomain_unregister: slot mismatch")

	currentProtDomains.prots[pd.slotIdx] = nil
	if currentProtDomains.freeSlots == nil {
		currentProtDomains.freeSlots = make([dynamic]int, 0, PROT_DOMAIN_ARRAY_START_CAP)
	}
	append(&currentProtDomains.freeSlots, pd.slotIdx)
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
