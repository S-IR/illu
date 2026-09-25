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

	newPD.weightFree = userschedule.SCHED_WEIGHT_TOTAL
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

protdomain_destroy :: proc(idx: int, caller: ^ProtectionDomain) -> ProtDomainTargetError {
	pd: ^ProtectionDomain
	{
		spinlock.rw_write_lock(&protDomainPool.rwLock)
		defer spinlock.rw_write_unlock(&protDomainPool.rwLock)
		pd = protdomain_resolve_target_DOESNT_LOCK(idx, caller) or_return
		if pd == caller do return .NoPermission
		protdomain_unlink_DOESNT_LOCK(idx)
	}
	protdomain_free(pd)
	return .None
}

protdomain_discard :: proc(idx: int, pd: ^ProtectionDomain) {
	{
		spinlock.rw_write_lock(&protDomainPool.rwLock)
		defer spinlock.rw_write_unlock(&protDomainPool.rwLock)
		if protDomainPool.prots[idx] != pd do return
		protdomain_unlink_DOESNT_LOCK(idx)
	}
	protdomain_free(pd)
}

protdomain_unlink_DOESNT_LOCK :: proc(idx: int) {
	assert(idx >= 0 && idx < len(protDomainPool.prots))
	assert(protDomainPool.prots[idx] != nil)
	protDomainPool.prots[idx] = nil
	if _, appendErr := append(&protDomainPool.freeSlots, idx); appendErr != nil do return
}

protdomain_free :: proc(pd: ^ProtectionDomain) {
	assert(pd != nil)
	assert(pd.pml4 != 0)
	grant_kill_all(pd)
	pmm.pml4_destroy(pd.pml4)
	if pd.pcid != 0 do pcid_free(pd.pcid)
	for resource in pd.resources do memory_underlay_release(resource.underlay)
	delete(pd.resources)
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

tlb_wait_domain_flushed :: proc(domain: ^ProtectionDomain) {
	self := gs_read_cpustate()
	for &cpu in cpus {
		if &cpu == self do continue
		start := intrinsics.atomic_load(&cpu.tlbEpoch)
		for intrinsics.atomic_load(&cpu.currentGrant.domain) == domain &&
		    intrinsics.atomic_load(&cpu.tlbEpoch) == start {
			intrinsics.atomic_add(&self.tlbEpoch, 1)
			grant_leave_if_killed(self)
			intrinsics.cpu_relax()
		}
	}
	ah.write_cr3(ah.read_cr3())
}

domain_unmap_page :: proc(domain: ^ProtectionDomain, logical: u64) {
	pmm.unmap_page(domain.pml4, logical)
	if cpuMeltdownVulnerable || logical >= pmm.identity_map_end() do return
	pmm.map_page(domain.pml4, logical, logical, ._4KB, {.Present, .Write, .NX})
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

domain_switch_cr3 :: proc "contextless" (domain: ^ProtectionDomain) {
	if !cpuHasPCID || domain.pcid == 0 {
		ah.write_cr3(domain.pml4)
		return
	}
	ah.write_cr3(domain.pml4 | u64(domain.pcid) | PCID_NOFLUSH_BIT)
}

kernel_switch_cr3 :: proc "contextless" () {
	if !cpuHasPCID {
		ah.write_cr3(pmm.kernelPML4)
		return
	}
	ah.write_cr3(pmm.kernelPML4 | u64(KERNEL_PCID) | PCID_NOFLUSH_BIT)
}

syscall_prot_domain_create :: proc "contextless" (
	authorityPtr: ^byte,
	regionsPtr, count: u64,
) -> (
	err: syscalls.ProtDomainCreateError,
	handle: int,
) {
	context = gKernelCtx
	callerDomain := gs_read_cpustate().currentGrant.domain
	assert(callerDomain != nil)
	if authorityPtr == nil do return .NoPermission, 0

	if count == 0 do return .InvalidRegionCount, 0
	regionBytes, overflowed := intrinsics.overflow_mul(count, size_of(syscalls.MemRegion))
	if overflowed do return .InvalidRegionCount, 0

	regions, regionsAllocErr := make([]syscalls.MemRegion, int(count))
	if regionsAllocErr != nil do return .OutOfMemory, 0
	defer delete(regions)
	{
		spinlock.rw_read_lock(&callerDomain.lock)
		defer spinlock.rw_read_unlock(&callerDomain.lock)
		if !user_range_accessible(callerDomain, u64(uintptr(authorityPtr)), 1, true) do return .NoPermission, 0
		if !user_range_accessible(callerDomain, regionsPtr, regionBytes, false) do return .InvalidRegionCount, 0
		mem.copy(raw_data(regions), rawptr(uintptr(regionsPtr)), int(regionBytes))
	}

	pd, pdIdx, allocErr := protdomain_new(authorityPtr)
	if allocErr != {} do return .OutOfMemory, 0
	defer if err != .None do protdomain_discard(pdIdx, pd)

	domains_write_lock(callerDomain, pd)
	defer domains_write_unlock(callerDomain, pd)
	for r in regions {
		if !mem_region_valid(r) do return .InvalidRegion, 0
		if region_covers_kernel(pd.pml4, r) do return .InvalidRegion, 0
		owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
		if !found do return .NotOwned, 0
		if r.phys + r.size > owner.overlay.phys + owner.overlay.size do return .NotOwned, 0
		if !region_flags_grantable(r.flags, owner.overlay.flags) do return .NotOwned, 0
		if resource_overlaps(pd.resources[:], r.phys, r.size) do return .InvalidRegion, 0

		pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
		for i in u64(0) ..< r.size / pageBytes {
			pmm.map_page(pd.pml4, r.phys + i * pageBytes, r.logical + i * pageBytes, r.pageSize, r.flags)
		}
		resource := MemoryResource {
			overlay = {
				phys = r.phys,
				logical = r.logical,
				size = r.size,
				pageSize = r.pageSize,
				flags = r.flags,
			},
			underlay = owner.underlay,
		}
		memory_underlay_increment(owner.underlay)
		if _, inserted := resource_insert(&pd.resources, resource); !inserted {
			memory_underlay_release(owner.underlay)
			return .TrackingFailed, 0
		}
	}
	return .None, pdIdx
}

syscall_prot_domain_edit :: proc "contextless" (
	handle: int,
	regionsPtr, count, opRaw: u64,
) -> (
	err: syscalls.ProtDomainEditError,
) {
	context = gKernelCtx
	callerDomain := gs_read_cpustate().currentGrant.domain
	assert(callerDomain != nil)

	if opRaw != u64(syscalls.MemRegionOp.Add) && opRaw != u64(syscalls.MemRegionOp.Delete) {
		return .InvalidOp
	}
	op := syscalls.MemRegionOp(opRaw)

	if count == 0 do return .InvalidRegionCount
	regionBytes, overflowed := intrinsics.overflow_mul(count, size_of(syscalls.MemRegion))
	if overflowed do return .InvalidRegionCount
	regions, allocErr := make([]syscalls.MemRegion, int(count))
	if allocErr != nil do return .OutOfMemory
	defer delete(regions)
	{
		spinlock.rw_read_lock(&callerDomain.lock)
		defer spinlock.rw_read_unlock(&callerDomain.lock)
		if !user_range_accessible(callerDomain, regionsPtr, regionBytes, false) do return .InvalidRegionCount
		mem.copy(raw_data(regions), rawptr(uintptr(regionsPtr)), int(regionBytes))
	}

	released, releasedErr := make([]^MemoryUnderlay, len(regions))
	if releasedErr != nil do return .OutOfMemory
	defer delete(released)
	releasedCount := 0
	target: ^ProtectionDomain
	defer if releasedCount > 0 {
		tlb_wait_domain_flushed(target)
		for underlay in released[:releasedCount] do memory_underlay_release(underlay)
	}

	spinlock.rw_read_lock(&protDomainPool.rwLock)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock)
	targetErr: ProtDomainTargetError
	target, targetErr = protdomain_resolve_target_DOESNT_LOCK(handle, callerDomain)
	if targetErr == .InvalidHandle do return .InvalidHandle
	if targetErr == .NoPermission do return .NoPermission

	domains_write_lock(callerDomain, target)
	defer domains_write_unlock(callerDomain, target)

	for r, i in regions {
		for j in i + 1 ..< len(regions) {
			other := regions[j]
			if r.phys == other.phys do return .InvalidRegion
			if op == .Add && resource_ranges_overlap(r.phys, r.size, other.phys, other.size) {
				return .InvalidRegion
			}
		}

		switch op {
		case .Add:
			if !mem_region_valid(r) do return .InvalidRegion
			if region_covers_kernel(target.pml4, r) do return .InvalidRegion
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			if !found do return .NotOwned
			if r.phys + r.size > owner.overlay.phys + owner.overlay.size do return .NotOwned
			if !region_flags_grantable(r.flags, owner.overlay.flags) do return .NotOwned
			if resource_overlaps(target.resources[:], r.phys, r.size) do return .InvalidRegion
		case .Delete:
			if _, found := resource_find_exact(target.resources[:], r.phys); !found do return .NotFound
		}
	}
	if op == .Add && reserve(&target.resources, len(target.resources) + len(regions)) != nil {
		return .OutOfMemory
	}

	for r in regions {
		switch op {
		case .Add:
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			assert(found)

			pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
			pageCount := r.size / pageBytes
			for i in u64(0) ..< pageCount {
				pmm.map_page(
					target.pml4,
					r.phys + i * pageBytes,
					r.logical + i * pageBytes,
					r.pageSize,
					r.flags,
				)
			}

			resource := MemoryResource {
				overlay = {
					phys = r.phys,
					logical = r.logical,
					size = r.size,
					pageSize = r.pageSize,
					flags = r.flags,
				},
				underlay = owner.underlay,
			}
			memory_underlay_increment(owner.underlay)
			_, inserted := resource_insert(&target.resources, resource)
			assert(inserted)

		case .Delete:
			removed, found := resource_remove(&target.resources, r.phys)
			assert(found)
			pageBytes := syscalls.mmap_page_size_bytes(removed.overlay.pageSize)
			pageCount := removed.overlay.size / pageBytes
			for i in u64(0) ..< pageCount {
				domain_unmap_page(target, removed.overlay.logical + i * pageBytes)
			}
			released[releasedCount] = removed.underlay
			releasedCount += 1
		}
	}

	return .None
}


syscall_prot_domain_destroy :: proc "contextless" (
	handle: int,
) -> (
	err: syscalls.ProtDomainDestroyError,
) {
	context = gKernelCtx
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)
	if protdomain_destroy(handle, caller) != .None do return .InvalidHandle
	return .None
}
