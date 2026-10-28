package kernel
import ah "../asm_helpers"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "core:container/bit_array"
import "core:mem"
import "pmm"
import "print"
ProtectionDomain :: struct {
	pml4:         u64,
	lock:         spinlock.RWLock,
	resources:    #soa[dynamic]MemoryResource,
	grantCpus:    bit_array.Bit_Array,
	authorityPtr: ^byte,
	weightFree:   u64,
	tlbGen:       u64,
	pcid:         u32,
}

protDomainPool := struct {
	rwLock:    spinlock.RWLock,
	prots:     [dynamic]^ProtectionDomain,
	freeSlots: [dynamic]int,
}{}

MEMORY_RESOURCES_STARTING_CAP :: 16

// Caller must hold protDomainPool.rwLock before calling this procedure and
// must keep it held while using the returned domain.
protdomain_resolve_target_DOESNT_LOCK :: proc(
	handle: int,
	caller: ^ProtectionDomain,
) -> (
	target: ^ProtectionDomain,
	err: shared.Error,
) {
	assert(caller != nil)

	if handle == max(int) do return caller, .None
	if handle < 0 || handle >= len(protDomainPool.prots) do return nil, .InvalidHandle
	target = protDomainPool.prots[handle]
	if target == nil do return nil, .InvalidHandle
	assert(target.authorityPtr != nil)

	spinlock.rw_read_lock(&caller.lock)
	defer spinlock.rw_read_unlock(&caller.lock)
	if !user_range_accessible(
		caller,
		u64(uintptr(target.authorityPtr)),
		size_of(target.authorityPtr^),
		true,
	) {
		return nil, .NoPermission
	}

	return target, .None
}

protdomain_new :: proc(authorityPtr: ^byte) -> (pd: ^ProtectionDomain, err: mem.Allocator_Error) {
	assert(len(cpus) > 0)
	assert(authorityPtr != nil)

	newPD := new(ProtectionDomain) or_return
	defer if err != nil do free(newPD)

	newPD.authorityPtr = authorityPtr

	newPD.resources = make(#soa[dynamic]MemoryResource, 0, MEMORY_RESOURCES_STARTING_CAP) or_return
	defer if err != nil do delete_soa(newPD.resources)

	newPD.pml4 = pmm.alloc_zeroed(shared.PAGE_SIZE)
	if newPD.pml4 == 0 do return nil, .Out_Of_Memory
	defer if err != nil do pmm.pml4_destroy(newPD.pml4)

	newPD.weightFree = userschedule.SCHED_WEIGHT_TOTAL
	if !bit_array.init(&newPD.grantCpus, len(cpus)) do return nil, .Out_Of_Memory

	pmm.map_kernel_image(newPD.pml4)
	pmm.pml4_share_kernel_half(newPD.pml4, entryRegionOnly = cpuMeltdownVulnerable)
	cpu_info_map(newPD.pml4)
	newPD.pcid = pcid_alloc()
	newPD.tlbGen = tlb_gen_next()
	return newPD, nil
}

protdomain_publish :: proc(pd: ^ProtectionDomain) -> (idx: int, err: mem.Allocator_Error) {
	assert(pd != nil)
	spinlock.rw_write_lock(&protDomainPool.rwLock)
	defer spinlock.rw_write_unlock(&protDomainPool.rwLock)

	if len(protDomainPool.freeSlots) > 0 {
		idx = pop(&protDomainPool.freeSlots)
		assert(idx >= 0 && idx < len(protDomainPool.prots))
		assert(protDomainPool.prots[idx] == nil)
		protDomainPool.prots[idx] = pd
		return idx, nil
	}
	append(&protDomainPool.prots, pd) or_return
	return len(protDomainPool.prots) - 1, nil
}

protdomain_destroy :: proc(idx: int, caller: ^ProtectionDomain) -> shared.Error {
	pd: ^ProtectionDomain
	{
		spinlock.rw_write_lock(&protDomainPool.rwLock)
		defer spinlock.rw_write_unlock(&protDomainPool.rwLock)
		pd = protdomain_resolve_target_DOESNT_LOCK(idx, caller) or_return
		if pd == caller do return .NoPermission
		assert(protDomainPool.prots[idx] == pd)
		protDomainPool.prots[idx] = nil
		append(&protDomainPool.freeSlots, idx)
	}
	protdomain_free(pd)
	return .None
}

protdomain_free :: proc(pd: ^ProtectionDomain) {
	assert(pd != nil)
	assert(pd.pml4 != 0)
	grant_kill_all(pd)
	pmm.pml4_destroy(pd.pml4)
	if pd.pcid != 0 do pcid_free(pd.pcid)
	for resource in pd.resources {
		memory_underlay_release(resource.underlay)
		delete(resource.rContractRules)
		delete(resource.wContractRules)
	}
	delete_soa(pd.resources)
	bit_array.destroy(&pd.grantCpus)
	free(pd)
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

tlbGenCounter: u64

tlb_gen_next :: proc "contextless" () -> u64 {
	return intrinsics.atomic_add(&tlbGenCounter, 1) + 1
}

domain_tlb_invalidate :: proc "contextless" (domain: ^ProtectionDomain) -> u64 {
	gen := tlb_gen_next()
	intrinsics.atomic_store(&domain.tlbGen, gen)
	return gen
}

tlb_shootdown :: proc(domain: ^ProtectionDomain, gen: u64) {
	assert(gen != 0)
	self := gs_read_cpustate()
	tlb_sync(self)
	for &cpu in cpus {
		if &cpu != self && cpu_tlb_stale(&cpu, domain, gen) do send_ipi(cpu_info(&cpu).apicId, VECTOR_APIC_IPI)
	}
	for &cpu in cpus {
		if &cpu == self do continue
		for cpu_tlb_stale(&cpu, domain, gen) {
			tlb_sync(self)
			grant_leave_if_killed(self)
			intrinsics.cpu_relax()
		}
	}
}

cpu_tlb_stale :: #force_inline proc "contextless" (
	cpu: ^CpuState,
	domain: ^ProtectionDomain,
	gen: u64,
) -> bool {
	return(
		intrinsics.atomic_load(&cpu.currentGrant.domain) == domain &&
		intrinsics.atomic_load(&cpu.tlbAckGen) < gen \
	)
}

tlb_sync :: proc "contextless" (cpu: ^CpuState) {
	domain := cpu.currentGrant.domain
	if domain == nil do return
	gen := intrinsics.atomic_load(&domain.tlbGen)
	if intrinsics.atomic_load(&cpu.tlbAckGen) >= gen do return
	if cpuMeltdownVulnerable {
		intrinsics.atomic_store(&cpu.tlbAckGen, gen)
		return
	}
	ah.write_cr3(domain_cr3(cpu, domain))
}

domain_cr3 :: proc "contextless" (cpu: ^CpuState, domain: ^ProtectionDomain) -> u64 {
	gen := intrinsics.atomic_load(&domain.tlbGen)
	intrinsics.atomic_store(&cpu.tlbAckGen, gen)
	if !cpuHasPCID || domain.pcid == 0 do return domain.pml4
	cr3 := domain.pml4 | u64(domain.pcid)
	if cpu.pcidSeenGen[domain.pcid] == gen do return cr3 | PCID_NOFLUSH_BIT
	cpu.pcidSeenGen[domain.pcid] = gen
	return cr3
}


KERNEL_PCID :: u32(1)
PCID_MAX :: u32(4096)

pcidAllocator := struct {
	lock: spinlock.Spinlock,
	next: u32,
	free: [dynamic]u32,
} {
	next = 2,
}

pcid_alloc :: proc() -> u32 {
	if !cpuHasPCID do return 0
	spinlock.lock(&pcidAllocator.lock)
	defer spinlock.unlock(&pcidAllocator.lock)
	if len(pcidAllocator.free) > 0 do return pop(&pcidAllocator.free)
	if pcidAllocator.next >= PCID_MAX do return 0
	pcid := pcidAllocator.next
	pcidAllocator.next += 1
	return pcid
}


pcid_free :: proc(pcid: u32) {
	if !cpuHasPCID do return
	if pcid == 0 do return
	spinlock.lock(&pcidAllocator.lock)
	defer spinlock.unlock(&pcidAllocator.lock)
	append(&pcidAllocator.free, pcid)
}

PCID_NOFLUSH_BIT :: u64(1) << 63

@(export, link_name = "kernel_cr3_value")
kernelCr3Value: u64

kernel_switch_cr3 :: proc "contextless" () {
	print.kassert(kernelCr3Value != 0)
	ah.write_cr3(kernelCr3Value)
}
syscall_prot_domain_create :: proc(
	authorityPtr: ^byte,
	regionsPtr, count: u64,
) -> (
	err: shared.Error,
	handle: int,
) {
	callerDomain := gs_read_cpustate().currentGrant.domain
	assert(callerDomain != nil)
	if authorityPtr == nil do return .NoPermission, 0

	if count == 0 || count > syscalls.MAX_REGIONS_PER_CALL do return .InvalidRegionCount, 0
	regionsBuf: [syscalls.MAX_REGIONS_PER_CALL]syscalls.MemRegion
	regions := regionsBuf[:count]
	if !user_copy_in(callerDomain, regions, regionsPtr) do return .InvalidRegionCount, 0
	for &r in regions do r.flags += {.Present, .User}
	{
		spinlock.rw_read_lock(&callerDomain.lock)
		defer spinlock.rw_read_unlock(&callerDomain.lock)
		if !user_range_accessible(callerDomain, u64(uintptr(authorityPtr)), 1, true) do return .NoPermission, 0
	}

	pd, allocErr := protdomain_new(authorityPtr)
	if allocErr != nil do return .OutOfMemory, 0
	defer if err != .None do protdomain_free(pd)

	{
		domains_write_lock(callerDomain, pd)
		defer domains_write_unlock(callerDomain, pd)

		for r, i in regions {
			if !mem_region_valid(r) || !region_mappable(pd.pml4, r) do return .InvalidRegion, 0
			for other in regions[i + 1:] {
				if resource_ranges_overlap(r.phys, r.size, other.phys, other.size) do return .InvalidRegion, 0
				if resource_ranges_overlap(r.logical, r.size, other.logical, other.size) do return .InvalidRegion, 0
			}
			ownerIdx, owned := resource_find_containing(callerDomain.resources[:], r.phys)
			if !owned do return .NotOwned, 0
			owner := callerDomain.resources[ownerIdx]
			if resource_contracted(owner) do return .NotOwned, 0
			if r.phys + r.size > owner.phys + owner.size do return .NotOwned, 0
			if !region_flags_grantable(r.flags, owner.flags) do return .NotOwned, 0
		}
		if reserve_soa(&pd.resources, len(regions)) != nil do return .OutOfMemory, 0

		detached: [dynamic]u64
		defer detached_tables_free(&detached)
		for r in regions {
			ownerIdx, owned := resource_find_containing(callerDomain.resources[:], r.phys)
			assert(owned)
			owner := callerDomain.resources[ownerIdx]
			granted := resource_granted(owner, r)
			_, inserted := resource_insert(&pd.resources, granted)
			assert(inserted)
			memory_underlay_increment(owner.underlay)
			resource_map(pd.pml4, granted, &detached)
		}
	}

	pdIdx, publishErr := protdomain_publish(pd)
	if publishErr != nil do return .OutOfMemory, 0
	return .None, pdIdx
}


syscall_prot_domain_edit :: proc(
	handle: int,
	regionsPtr, count, opRaw: u64,
) -> (
	err: shared.Error,
) {
	callerDomain := gs_read_cpustate().currentGrant.domain
	assert(callerDomain != nil)

	if opRaw != u64(syscalls.MemRegionOp.Add) && opRaw != u64(syscalls.MemRegionOp.Delete) {
		return .InvalidOp
	}
	op := syscalls.MemRegionOp(opRaw)

	if count == 0 || count > syscalls.MAX_REGIONS_PER_CALL do return .InvalidRegionCount
	regionsBuf: [syscalls.MAX_REGIONS_PER_CALL]syscalls.MemRegion
	regions := regionsBuf[:count]
	if !user_copy_in(callerDomain, regions, regionsPtr) do return .InvalidRegionCount
	for &r in regions do r.flags += {.Present, .User}

	released: [syscalls.MAX_REGIONS_PER_CALL]^MemoryUnderlay
	releasedCount := 0
	target: ^ProtectionDomain
	tlbGen: u64
	detached: [dynamic]u64
	defer {
		if tlbGen != 0 do tlb_shootdown(target, tlbGen)
		for underlay in released[:releasedCount] do memory_underlay_release(underlay)
		detached_tables_free(&detached)
	}

	spinlock.rw_read_lock(&protDomainPool.rwLock)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock)
	target = protdomain_resolve_target_DOESNT_LOCK(handle, callerDomain) or_return

	domains_write_lock(callerDomain, target)
	defer domains_write_unlock(callerDomain, target)

	for r, i in regions {
		for j in i + 1 ..< len(regions) {
			other := regions[j]
			if r.phys == other.phys do return .InvalidRegion
			if op == .Add {
				if resource_ranges_overlap(r.phys, r.size, other.phys, other.size) do return .InvalidRegion
				if resource_ranges_overlap(r.logical, r.size, other.logical, other.size) do return .InvalidRegion
			}

		}

		switch op {
		case .Add:
			if !mem_region_valid(r) do return .InvalidRegion
			if !region_mappable(target.pml4, r) do return .InvalidRegion
			ownerIdx, found := resource_find_containing(callerDomain.resources[:], r.phys)
			if !found do return .NotOwned
			owner := callerDomain.resources[ownerIdx]
			if resource_contracted(owner) do return .NotOwned

			if r.phys + r.size > owner.phys + owner.size do return .NotOwned
			if !region_flags_grantable(r.flags, owner.flags) do return .NotOwned
			if resource_overlaps(target.resources[:], r.phys, r.size) do return .InvalidRegion
		case .Delete:
			if _, found := resource_find_exact(target.resources[:], r.phys); !found do return .NotFound
		}
	}
	if op == .Add && reserve_soa(&target.resources, len(target.resources) + len(regions)) != nil {
		return .OutOfMemory
	}

	for r in regions {
		switch op {
		case .Add:
			ownerIdx, found := resource_find_containing(callerDomain.resources[:], r.phys)
			assert(found)
			owner := callerDomain.resources[ownerIdx]
			granted := resource_granted(owner, r)
			_, inserted := resource_insert(&target.resources, granted)
			assert(inserted)
			memory_underlay_increment(owner.underlay)
			resource_map(target.pml4, granted, &detached)
			if len(detached) > 0 && tlbGen == 0 do tlbGen = domain_tlb_invalidate(target)

		case .Delete:
			removed, found := resource_remove(&target.resources, r.phys)
			assert(found)
			delete(removed.rContractRules)
			delete(removed.wContractRules)
			released[releasedCount] = removed.underlay
			releasedCount += 1
			if removed.flags == {} do continue

			resource_unmap(target.pml4, removed)
			if tlbGen == 0 do tlbGen = domain_tlb_invalidate(target)

		}
	}

	return .None
}


syscall_prot_domain_destroy :: proc(handle: int) -> (err: shared.Error) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)
	return protdomain_destroy(handle, caller)
}
