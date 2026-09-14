package kernel
import "../lib/spinlock"
import "../lib/syscalls"
import "pmm"
import "print"
ProtectionDomain :: struct {
	pml4:           u64,
	lock:           spinlock.RWLock,
	resources:      [dynamic]MemoryResource,
	executionCount: int,
	slotIdx:        int,
	generation:     u32,
	executions:     [dynamic]^Execution,
	killed:         bool,
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
	pd.generation += 1
}

protdomain_handle_encode :: proc "contextless" (pd: ^ProtectionDomain) -> u64 {
	return u64(u32(pd.slotIdx)) | (u64(pd.generation) << 32)
}

protdomain_handle_resolve :: proc "contextless" (handle: u64) -> ^ProtectionDomain {
	idx := int(u32(handle))
	gen := u32(handle >> 32)
	spinlock.lock(&currentProtDomains.lock)
	defer spinlock.unlock(&currentProtDomains.lock)
	if idx < 0 || idx >= len(currentProtDomains.prots) do return nil
	pd := currentProtDomains.prots[idx]
	if pd == nil || pd.generation != gen do return nil
	return pd
}

// handle == 0 means "the caller's own domain" -- 0 can never be a real
// encoded handle since generation starts at 1 and only increases.
protdomain_resolve_target :: proc "contextless" (
	handle: u64,
	callerDomain: ^ProtectionDomain,
) -> ^ProtectionDomain {
	if handle == 0 do return callerDomain
	return protdomain_handle_resolve(handle)
}

protdomain_unregister :: proc(pd: ^ProtectionDomain) {
	print.kassert(pd != nil, "protdomain_unregister: nil domain")
	if pd == nil do return

	spinlock.lock(&currentProtDomains.lock)
	defer spinlock.unlock(&currentProtDomains.lock)

	print.kassert(currentProtDomains.prots != nil, "protdomain_unregister: registry empty")
	print.kassert(
		pd.slotIdx >= 0 && pd.slotIdx < len(currentProtDomains.prots),
		"protdomain_unregister: bad slotIdx",
	)
	print.kassert(
		currentProtDomains.prots[pd.slotIdx] == pd,
		"protdomain_unregister: slot mismatch",
	)

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
		if resources[mid].region.phys <= phys {
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
	if candidate.region.phys != phys do return nil, false
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
	if phys < candidate.region.phys || phys >= candidate.region.phys + candidate.region.size do return nil, false
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
	if resource.region.size == 0 do return nil, false
	if resource.region.phys + resource.region.size < resource.region.phys do return nil, false

	insertIdx := resource_upper_bound(resources[:], resource.region.phys)
	if insertIdx > 0 {
		prev := resources[insertIdx - 1]
		if resource_ranges_overlap(resource.region.phys, resource.region.size, prev.region.phys, prev.region.size) do return nil, false
	}
	if insertIdx < len(resources) {
		next := resources[insertIdx]
		if resource_ranges_overlap(resource.region.phys, resource.region.size, next.region.phys, next.region.size) do return nil, false
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
	if candidate.region.phys != phys do return {}, false

	removed = candidate^
	ordered_remove(resources, insertIdx - 1)
	return removed, true
}

// Every syscall that reads or mutates a ProtectionDomain's `resources` array
// must hold `lock` (not just take a pointer and hope) -- see the write-up
// where this was added. domains_write_lock/unlock take one or two domains'
// locks together, collapsing to a single lock when the caller is editing its
// own domain (target == callerDomain) so that case can't deadlock on itself,
// and otherwise locking in address order so two threads editing the same
// pair of domains in opposite order can't deadlock on each other.
domains_write_lock :: proc "contextless" (a, b: ^ProtectionDomain) {
	if a == b {
		spinlock.rw_write_lock(&a.lock)
		return
	}
	first, second := a, b
	if uintptr(a) > uintptr(b) do first, second = b, a
	spinlock.rw_write_lock(&first.lock)
	spinlock.rw_write_lock(&second.lock)
}

domains_write_unlock :: proc "contextless" (a, b: ^ProtectionDomain) {
	if a == b {
		spinlock.rw_write_unlock(&a.lock)
		return
	}
	first, second := a, b
	if uintptr(a) > uintptr(b) do first, second = b, a
	spinlock.rw_write_unlock(&second.lock)
	spinlock.rw_write_unlock(&first.lock)
}

resource_overlap_existing :: proc "contextless" (
	resources: []MemoryResource,
	phys, size: u64,
) -> bool {
	insertedIdx := resource_upper_bound(resources, phys)
	if insertedIdx > 0 {
		prev := resources[insertedIdx - 1]
		if resource_ranges_overlap(phys, size, prev.region.phys, prev.region.size) do return true
	}
	if insertedIdx < len(resources) {
		next := resources[insertedIdx]
		if resource_ranges_overlap(phys, size, next.region.phys, next.region.size) do return true
	}
	return false
}
