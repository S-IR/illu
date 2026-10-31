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

ProtDomainPool :: struct {
	rwLock:    spinlock.RWLock,
	prots:     [dynamic]^ProtectionDomain,
	freeSlots: [dynamic]int,
}

MEMORY_RESOURCES_STARTING_CAP :: 16

// Caller must hold kernelState.protDomainPool.rwLock before calling this procedure and
// must keep it held while using the returned domain.
protdomain_resolve_target_NO_LOCK :: proc(
	handle: int,
	caller: ^ProtectionDomain,
) -> (
	target: ^ProtectionDomain,
	err: shared.Error,
) {
	assert(caller != nil)

	if handle == max(int) do return caller, .None
	if handle < 0 || handle >= len(kernelState.protDomainPool.prots) do return nil, .InvalidHandle
	target = kernelState.protDomainPool.prots[handle]
	if target == nil do return nil, .InvalidHandle
	assert(target.authorityPtr != nil)

	domain_read_lock(caller)
	if !user_range_accessible_NO_LOCK(
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
	assert(len(kernelState.cpus) > 0)
	assert(authorityPtr != nil)

	newPD := new(ProtectionDomain) or_return
	defer if err != nil do free(newPD)

	newPD.authorityPtr = authorityPtr

	newPD.resources = make(#soa[dynamic]MemoryResource, 0, MEMORY_RESOURCES_STARTING_CAP) or_return
	defer if err != nil do delete_soa(newPD.resources)

	newPD.pml4 = pmm.alloc_zeroed(&kernelState.pmm, shared.PAGE_SIZE)
	if newPD.pml4 == 0 do return nil, .Out_Of_Memory
	defer if err != nil do pmm.pml4_destroy(&kernelState.pmm, newPD.pml4)

	newPD.weightFree = userschedule.SCHED_WEIGHT_TOTAL
	if !bit_array.init(&newPD.grantCpus, len(kernelState.cpus)) do return nil, .Out_Of_Memory

	pmm.map_kernel_image(&kernelState.pmm, newPD.pml4)
	pmm.pml4_share_kernel_half(newPD.pml4, entryRegionOnly = cpuMeltdownVulnerable)
	cpu_info_map(newPD.pml4)
	newPD.pcid = pcid_alloc()
	newPD.tlbGen = tlb_gen_next()
	return newPD, nil
}

protdomain_publish :: proc(pd: ^ProtectionDomain) -> (idx: int, err: mem.Allocator_Error) {
	assert(pd != nil)
	poolGuards := [][]u8 {
		mem.ptr_to_bytes(&kernelState.protDomainPool),
		mem.slice_to_bytes(kernelState.protDomainPool.prots[:]),
		mem.slice_to_bytes(kernelState.protDomainPool.freeSlots[:]),
	}
	spinlock.rw_write_lock(&kernelState.protDomainPool.rwLock, poolGuards)
	defer spinlock.rw_write_unlock(&kernelState.protDomainPool.rwLock, poolGuards)

	if len(kernelState.protDomainPool.freeSlots) > 0 {
		idx = pop(&kernelState.protDomainPool.freeSlots)
		assert(idx >= 0 && idx < len(kernelState.protDomainPool.prots))
		assert(kernelState.protDomainPool.prots[idx] == nil)
		kernelState.protDomainPool.prots[idx] = pd
		return idx, nil
	}
	append(&kernelState.protDomainPool.prots, pd) or_return
	return len(kernelState.protDomainPool.prots) - 1, nil
}

protdomain_destroy :: proc(idx: int, caller: ^ProtectionDomain) -> shared.Error {
	pd: ^ProtectionDomain
	{
		poolGuards := [][]u8 {
			mem.ptr_to_bytes(&kernelState.protDomainPool),
			mem.slice_to_bytes(kernelState.protDomainPool.prots[:]),
			mem.slice_to_bytes(kernelState.protDomainPool.freeSlots[:]),
		}
		spinlock.rw_write_lock(&kernelState.protDomainPool.rwLock, poolGuards)
		defer spinlock.rw_write_unlock(&kernelState.protDomainPool.rwLock, poolGuards)
		pd = protdomain_resolve_target_NO_LOCK(idx, caller) or_return
		if pd == caller do return .NoPermission
		assert(kernelState.protDomainPool.prots[idx] == pd)
		kernelState.protDomainPool.prots[idx] = nil
		append(&kernelState.protDomainPool.freeSlots, idx)
	}
	protdomain_free(pd)
	return .None
}

protdomain_free :: proc(pd: ^ProtectionDomain) {
	assert(pd != nil)
	assert(pd.pml4 != 0)
	grant_kill_all(pd)
	ring_domain_orphan(pd)
	pmm.pml4_destroy(&kernelState.pmm, pd.pml4)
	if pd.pcid != 0 do pcid_free(pd.pcid)
	for resource in pd.resources {
		memory_underlay_release(resource.underlay)
		contract_rules_free(resource.contract)
	}
	delete_soa(pd.resources)
	bit_array.destroy(&pd.grantCpus)
	free(pd)
}

domain_guards :: proc "contextless" (d: ^ProtectionDomain) -> [3][]byte {
	return {
		mem.ptr_to_bytes(d),
		mem.slice_to_bytes(d.grantCpus.bits[:]),
		resources_backing_bytes(&d.resources),
	}
}

@(deferred_out = domain_read_unlock)
domain_read_lock :: proc "contextless" (d: ^ProtectionDomain) -> (^ProtectionDomain, [3][]byte) {
	guards := domain_guards(d)
	spinlock.rw_read_lock(&d.lock, guards[:])
	return d, guards
}

domain_read_unlock :: proc "contextless" (d: ^ProtectionDomain, g: [3][]byte) {
	guards := g
	spinlock.rw_read_unlock(&d.lock, guards[:])
}

@(deferred_out = domain_write_unlock)
domain_write_lock :: proc "contextless" (d: ^ProtectionDomain) -> (^ProtectionDomain, [3][]byte) {
	guards := domain_guards(d)
	spinlock.rw_write_lock(&d.lock, guards[:])
	return d, guards
}

domain_write_unlock :: proc "contextless" (d: ^ProtectionDomain, g: [3][]byte) {
	guards := g
	spinlock.rw_write_unlock(&d.lock, guards[:])
}

domains_write_lock :: proc "contextless" (a, b: ^ProtectionDomain) {
	if a == b {
		aGuards := domain_guards(a)
		spinlock.rw_write_lock(&a.lock, aGuards[:])
		return
	}
	first, second := a, b
	if uintptr(a) > uintptr(b) do first, second = b, a
	firstGuards := domain_guards(first)
	secondGuards := domain_guards(second)
	spinlock.rw_write_lock(&first.lock, firstGuards[:])
	spinlock.rw_write_lock(&second.lock, secondGuards[:])
}

domains_write_unlock :: proc "contextless" (a, b: ^ProtectionDomain) {
	if a == b {
		aGuards := domain_guards(a)
		spinlock.rw_write_unlock(&a.lock, aGuards[:])
		return
	}
	first, second := a, b
	if uintptr(a) > uintptr(b) do first, second = b, a
	firstGuards := domain_guards(first)
	secondGuards := domain_guards(second)
	spinlock.rw_write_unlock(&second.lock, secondGuards[:])
	spinlock.rw_write_unlock(&first.lock, firstGuards[:])
}

tlb_gen_next :: proc "contextless" () -> u64 {
	return intrinsics.atomic_add(&kernelState.tlbGenCounter, 1) + 1
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
	for &cpu in kernelState.cpus {
		if &cpu != self && cpu_tlb_stale(&cpu, domain, gen) do send_ipi(cpu_info(&cpu).apicId, VECTOR_APIC_IPI)
	}
	for &cpu in kernelState.cpus {
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

PcidAllocator :: struct {
	lock: spinlock.Spinlock,
	next: u32,
	free: [dynamic]u32,
}

pcid_alloc :: proc() -> u32 {
	if !cpuHasPCID do return 0
	pcidGuards := [][]u8 {
		mem.ptr_to_bytes(&kernelState.pcidAllocator),
		mem.slice_to_bytes(kernelState.pcidAllocator.free[:]),
	}
	spinlock.lock(&kernelState.pcidAllocator.lock, pcidGuards)
	defer spinlock.unlock(&kernelState.pcidAllocator.lock, pcidGuards)
	if len(kernelState.pcidAllocator.free) > 0 do return pop(&kernelState.pcidAllocator.free)
	if kernelState.pcidAllocator.next >= PCID_MAX do return 0
	pcid := kernelState.pcidAllocator.next
	kernelState.pcidAllocator.next += 1
	return pcid
}


pcid_free :: proc(pcid: u32) {
	if !cpuHasPCID do return
	if pcid == 0 do return
	pcidGuards := [][]u8 {
		mem.ptr_to_bytes(&kernelState.pcidAllocator),
		mem.slice_to_bytes(kernelState.pcidAllocator.free[:]),
	}
	spinlock.lock(&kernelState.pcidAllocator.lock, pcidGuards)
	defer spinlock.unlock(&kernelState.pcidAllocator.lock, pcidGuards)
	append(&kernelState.pcidAllocator.free, pcid)
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
	handle: int,
	err: shared.Error,
) {
	callerDomain := gs_read_cpustate().currentGrant.domain
	assert(callerDomain != nil)
	if authorityPtr == nil do return 0, .NoPermission

	if count == 0 || count > syscalls.MAX_REGIONS_PER_CALL do return 0, .InvalidRegionCount
	regionsBuf: [syscalls.MAX_REGIONS_PER_CALL]syscalls.MemRegion
	regions := regionsBuf[:count]
	if !user_copy_in(callerDomain, regions, regionsPtr) do return 0, .InvalidRegionCount
	for &r in regions {
		if .Present in r.flags do r.flags += {.User}
	}
	{
		domain_read_lock(callerDomain)
		if !user_range_accessible_NO_LOCK(callerDomain, u64(uintptr(authorityPtr)), 1, true) do return 0, .NoPermission
	}

	pd, allocErr := protdomain_new(authorityPtr)
	if allocErr != nil do return 0, .OutOfMemory
	defer if err != .None do protdomain_free(pd)

	{
		domains_write_lock(callerDomain, pd)
		defer domains_write_unlock(callerDomain, pd)

		for r, i in regions {
			if !mem_region_valid(r) do return 0, .InvalidRegion
			if .Present in r.flags {
				if !region_mappable(pd.pml4, r) do return 0, .InvalidRegion
			}
			for other in regions[i + 1:] {
				if resource_ranges_overlap(r.phys, r.size, other.phys, other.size) do return 0, .InvalidRegion
				if .Present in r.flags && .Present in other.flags {
					if resource_ranges_overlap(r.logical, r.size, other.logical, other.size) do return 0, .InvalidRegion
				}
			}
			ownerIdx, owned := resource_find_containing(callerDomain.resources[:], r.phys)
			if !owned do return 0, .NotOwned
			owner := callerDomain.resources[ownerIdx]
			if resource_contracted(owner) do return 0, .NotOwned
			if r.phys + r.size > owner.phys + owner.size do return 0, .NotOwned
			if !region_flags_grantable(r.flags, owner.flags) do return 0, .NotOwned
		}
		if reserve_soa(&pd.resources, len(regions)) != nil do return 0, .OutOfMemory

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
			if .Present in granted.flags {
				resource_map(pd.pml4, granted, &detached)
			}
		}
	}

	pdIdx, publishErr := protdomain_publish(pd)
	if publishErr != nil do return 0, .OutOfMemory
	return pdIdx, .None
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
	for &r in regions {
		if .Present in r.flags do r.flags += {.User}
	}

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

	poolGuards := [][]u8 {
		mem.ptr_to_bytes(&kernelState.protDomainPool),
		mem.slice_to_bytes(kernelState.protDomainPool.prots[:]),
		mem.slice_to_bytes(kernelState.protDomainPool.freeSlots[:]),
	}
	spinlock.rw_read_lock(&kernelState.protDomainPool.rwLock, poolGuards)
	defer spinlock.rw_read_unlock(&kernelState.protDomainPool.rwLock, poolGuards)
	target = protdomain_resolve_target_NO_LOCK(handle, callerDomain) or_return

	domains_write_lock(callerDomain, target)
	defer domains_write_unlock(callerDomain, target)

	for r, i in regions {
		for j in i + 1 ..< len(regions) {
			other := regions[j]
			if r.phys == other.phys do return .InvalidRegion
			if op == .Add {
				if resource_ranges_overlap(r.phys, r.size, other.phys, other.size) do return .InvalidRegion
				if .Present in r.flags && .Present in other.flags {
					if resource_ranges_overlap(r.logical, r.size, other.logical, other.size) do return .InvalidRegion
				}
			}

		}

		switch op {
		case .Add:
			if !mem_region_valid(r) do return .InvalidRegion
			if .Present in r.flags {
				if !region_mappable(target.pml4, r) do return .InvalidRegion
			}
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
			if .Present in granted.flags {
				resource_map(target.pml4, granted, &detached)
				if len(detached) > 0 && tlbGen == 0 do tlbGen = domain_tlb_invalidate(target)
			}

		case .Delete:
			removed, found := resource_remove(&target.resources, r.phys)
			assert(found)
			contract_rules_free(removed.contract)
			released[releasedCount] = removed.underlay
			releasedCount += 1
			if .Present not_in removed.flags do continue

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
