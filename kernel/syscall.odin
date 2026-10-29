package kernel
import "../lib/lmem"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "core:mem"
import "pmm"

import "print"


@(export)
syscall_return_noncanonical :: proc "c" () -> ! {
	context = gKernelCtx
	assert(gs_read_cpustate().currentGrant.domain != nil)
	print.serial_writeln("syscall: non-canonical return rip, grant dropped")
	grant_exit()
}
serialPrintLock: spinlock.Spinlock

syscall_mmap :: proc(regionsPtr: u64, regionsCount: u64) -> (err: shared.Error, phys: u64) {
	domain := gs_read_cpustate().currentGrant.domain
	assert(domain != nil)
	if regionsCount == 0 || regionsCount > syscalls.MAX_REGIONS_PER_CALL do return .InvalidSize, 0
	regionsBuf: [syscalls.MAX_REGIONS_PER_CALL]syscalls.MMapRegion
	regions := regionsBuf[:regionsCount]
	if !user_copy_in(domain, regions, regionsPtr) do return .InvalidSize, 0

	offsetsBuf: [syscalls.MAX_REGIONS_PER_CALL]u64
	totalBytes: u64
	for r, i in regions {
		if r.count == 0 do return .InvalidSize, 0
		if !page_size_usable(r.pageSize) do return .InvalidPageSize, 0
		pageBytes := lmem.page_bytes(r.pageSize)
		rBytes, mulOverflow := intrinsics.overflow_mul(r.count, pageBytes)
		start := (totalBytes + pageBytes - 1) & ~(pageBytes - 1)
		end, addOverflow := intrinsics.overflow_add(start, rBytes)
		if mulOverflow || addOverflow || end > USER_ADDR_END do return .InvalidSize, 0
		offsetsBuf[i] = start
		totalBytes = end
	}

	allocatedPhys := pmm.alloc_zeroed(totalBytes)
	if allocatedPhys == 0 do return .OutOfMemory, 0
	defer if err != .None do pmm.free_pages(allocatedPhys, totalBytes)

	tlbGen: u64
	detached: [dynamic]u64
	defer if tlbGen != 0 {
		tlb_shootdown(domain, tlbGen)
		detached_tables_free(&detached)
	}

	domainGuards := [][]u8{mem.ptr_to_bytes(domain), mem.slice_to_bytes(domain.grantCpus.bits[:])}
	spinlock.rw_write_lock(&domain.lock, domainGuards)
	defer spinlock.rw_write_unlock(&domain.lock, domainGuards)

	assert(!resource_overlaps(domain.resources[:], allocatedPhys, totalBytes))
	for r, i in regions {
		regionPhys := allocatedPhys + offsetsBuf[i]
		assert(regionPhys % lmem.page_bytes(r.pageSize) == 0)
		region := syscalls.MemRegion {
			phys     = regionPhys,
			logical  = regionPhys,
			size     = r.count * lmem.page_bytes(r.pageSize),
			pageSize = r.pageSize,
		}
		if !region_mappable(domain.pml4, region) do return .AddressInUse, 0
	}
	if reserve_soa(&domain.resources, len(domain.resources) + len(regions)) != nil do return .OutOfMemory, 0

	underlay := memory_underlay_create(allocatedPhys, totalBytes, .AllocatedRAM)
	for _ in 1 ..< len(regions) do memory_underlay_increment(underlay)

	for r, i in regions {
		regionPhys := allocatedPhys + offsetsBuf[i]
		resource := MemoryResource {
			phys     = regionPhys,
			logical  = regionPhys,
			size     = r.count * lmem.page_bytes(r.pageSize),
			pageSize = r.pageSize,
			flags    = (r.flags & {.Write, .NX, .PWT, .PCD}) + {.Present, .User},
			underlay = underlay,
		}
		_, inserted := resource_insert(&domain.resources, resource)
		assert(inserted)
		resource_map(domain.pml4, resource, &detached)
	}
	if len(detached) > 0 do tlbGen = domain_tlb_invalidate(domain)
	return .None, allocatedPhys
}

@(export)
syscall_dispatch :: proc "sysv" (nr, a1, a2, a3, a4, a5, a6: u64) -> (err: u64, r1: u64) {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	assert(cpu.currentGrant.domain != nil)
	defer if cpuMeltdownVulnerable do cpu.userCr3 = domain_cr3(cpu, cpu.currentGrant.domain)
	defer if intrinsics.atomic_load(&cpu.currentGrant.weight) == 0 do grant_exit()

	switch syscalls.Syscall(nr) {
	case .MMap:
		mmapErr, addr := syscall_mmap(a1, a2)
		return u64(mmapErr), addr
	case .ProtDomainCreate:
		err, handle := syscall_prot_domain_create((^byte)(uintptr(a1)), a2, a3)
		return u64(err), transmute(u64)handle
	case .ProtDomainEdit:
		return u64(syscall_prot_domain_edit(transmute(int)a1, a2, a3, a4)), 0
	case .ProtDomainDestroy:
		return u64(syscall_prot_domain_destroy(transmute(int)a1)), 0

	case .GrantSpawn:
		return u64(syscall_grant_spawn(transmute(int)a1, a2, a3, a4, a5)), 0
	case .GrantEdit:
		return u64(syscall_grant_edit(transmute(int)a1, a2, a3)), 0

	case .WaitOn:
		return u64(syscall_wait_on(a1, a2, a3)), 0

	case .ContractCreate:
		return u64(syscall_contract_create(transmute(int)a1, a2, a3, a4)), 0
	case .ContractMemoryAccess:
		return u64(syscall_contract_memory_access(a1, a2, a3, a4)), 0

	case .DebugPrint:
		domain := cpu.currentGrant.domain
		domainGuards := [][]u8{mem.ptr_to_bytes(domain), mem.slice_to_bytes(domain.grantCpus.bits[:])}
		spinlock.rw_read_lock(&domain.lock, domainGuards)
		defer spinlock.rw_read_unlock(&domain.lock, domainGuards)
		if !user_range_accessible(domain, a1, a2, false) do return max(u64), max(u64)

		label := string(([^]u8)(pmm.phys_to_ptr(a1))[:a2])
		spinlock.lock(&serialPrintLock, nil)
		defer spinlock.unlock(&serialPrintLock, nil)
		print.serial_write("dbg: ")
		print.serial_writeln(label)
	}
	return max(u64), max(u64)
}
