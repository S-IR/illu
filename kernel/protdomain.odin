package kernel
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "core:container/bit_array"
import "core:mem"
import "pmm"
ProtectionDomain :: struct {
	pml4:         u64,
	lock:         spinlock.RWLock,
	resources:    [dynamic]MemoryResource,
	grantCpus:    bit_array.Bit_Array,
	authorityPtr: ^byte,
	weightFree:   u64,
	pcid:         u32,
}

protDomainPool := struct {
	rwLock:    spinlock.RWLock,
	prots:     [dynamic]^ProtectionDomain,
	freeSlots: [dynamic]int,
}{}

PROT_DOMAIN_ARRAY_START_CAP :: 64
MEMORY_RESOURCES_STARTING_CAP :: 16

ProtDomainTargetError :: enum {
	None,
	InvalidHandle,
	NoPermission,
}

// Caller must hold protDomainPool.rwLock before calling this procedure and
// must keep it held while using the returned domain.
protdomain_resolve_target_DOESNT_LOCK :: proc(
	handle: int,
	caller: ^ProtectionDomain,
) -> (
	target: ^ProtectionDomain,
	err: ProtDomainTargetError,
) {
	if caller == nil do return nil, .NoPermission

	if handle == max(int) {
		target = caller
	} else {
		if handle < 0 || handle >= len(protDomainPool.prots) do return nil, .InvalidHandle
		target = protDomainPool.prots[handle]
		if target == nil do return nil, .InvalidHandle
	}

	if target.authorityPtr == nil do return nil, .NoPermission
	spinlock.rw_read_lock(&caller.lock)
	defer spinlock.rw_read_unlock(&caller.lock)
	if !user_range_accessible(caller, u64(uintptr(target.authorityPtr)), size_of(target.authorityPtr^), true) {
		return nil, .NoPermission
	}

	return target, .None
}

protdomain_new :: proc(
	authorityPtr: ^byte,
) -> (
	pd: ^ProtectionDomain,
	idx: int = -1,
	err: mem.Allocator_Error,
) {
	assert(len(cpus) > 0)
	assert(authorityPtr != nil)

	newPD, allocErr := new(ProtectionDomain)
	if allocErr != {} do return nil, -1, allocErr
	assert(newPD != nil)
	defer if err != {} do free(newPD)

	newPD.authorityPtr = authorityPtr

	newPD.resources = make([dynamic]MemoryResource, 0, MEMORY_RESOURCES_STARTING_CAP) or_return
	defer if err != {} do delete(newPD.resources)

	newPD.pml4 = pmm.alloc_zeroed(shared.PAGE_SIZE)
	if newPD.pml4 == 0 do return nil, -1, .Out_Of_Memory
	defer if err != {} do pmm.pml4_destroy(newPD.pml4)

	newPD.weightFree = syscalls.SCHED_WEIGHT_TOTAL
	if !bit_array.init(&newPD.grantCpus, len(cpus)) do return nil, -1, .Out_Of_Memory
	defer if err != {} do bit_array.destroy(&newPD.grantCpus)

	if cpuMeltdownVulnerable {
		pmm.pml4_map_kernel_image(newPD.pml4)
	} else {
		pmm.pml4_deep_copy(newPD.pml4, pmm.kernelPML4, true)
	}
	cpu_info_map(newPD.pml4)

	if cpuHasPCID {
		newPD.pcid = pcid_alloc()
		assert(newPD.pcid != 0)
		defer if err != {} do pcid_free(newPD.pcid)
	}

	spinlock.rw_write_lock(&protDomainPool.rwLock)
	defer spinlock.rw_write_unlock(&protDomainPool.rwLock)

	if protDomainPool.prots == nil {
		assert(protDomainPool.freeSlots == nil || len(protDomainPool.freeSlots) == 0)
		protDomainPool.prots = make(
			[dynamic]^ProtectionDomain,
			0,
			PROT_DOMAIN_ARRAY_START_CAP,
		) or_return
	}

	if len(protDomainPool.freeSlots) > 0 {
		idx = pop(&protDomainPool.freeSlots)
		assert(idx >= 0 && idx < len(protDomainPool.prots))
		assert(protDomainPool.prots[idx] == nil)
	} else {
		idx = len(protDomainPool.prots)
		append(&protDomainPool.prots, (^ProtectionDomain)(nil)) or_return
	}

	assert(idx >= 0 && idx < len(protDomainPool.prots))
	assert(protDomainPool.prots[idx] == nil)
	protDomainPool.prots[idx] = newPD
	pd = newPD
	newPD = nil

	return pd, idx, {}
}

protdomain_destroy :: proc(idx: int) -> (err: mem.Allocator_Error) {
	pd: ^ProtectionDomain
	{
		spinlock.rw_write_lock(&protDomainPool.rwLock)
		defer spinlock.rw_write_unlock(&protDomainPool.rwLock)

		if protDomainPool.prots == nil do return
		if idx < 0 || idx >= len(protDomainPool.prots) do return

		pd = protDomainPool.prots[idx]
		assert(pd != nil)
		if pd == nil do return
		assert(pd.pml4 != 0)
		assert(pd.resources != nil)
		assert(pd.authorityPtr != nil)

		append(&protDomainPool.freeSlots, idx) or_return
		protDomainPool.prots[idx] = nil
	}

	grant_kill_all(pd)
	pmm.pml4_destroy(pd.pml4)
	if pd.pcid != 0 do pcid_free(pd.pcid)
	delete(pd.resources)
	bit_array.destroy(&pd.grantCpus)
	free(pd)
	return
}

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
