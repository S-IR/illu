package kernel
import ah "../asm_helpers"
import "../lib/lmem"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"


@(export)
syscall_dispatch :: proc "sysv" (nr, a1, a2, a3, a4, a5: u64) -> (err: u64, r1: u64) {

	switch syscalls.Syscall(nr) {
	case .Exit:
		print.serial_write("exit code: ")
		print.serial_write_u64(a1)
		print.serial_writeln("")
		exec_exit_current()
	case .MMap:
		count := a1
		if count == 0 do return u64(syscalls.MMapError.InvalidSize), 0

		if a2 >= len(lmem.PageSize) do return u64(syscalls.MMapError.InvalidPageSize), 0
		pageSize := transmute(lmem.PageSize)a2

		pageFlags := transmute(lmem.PageFlags)a3
		pageFlags += {.User}

		mmapErr, addr := syscall_mmap(count, pageSize, pageFlags)
		return u64(mmapErr), addr
	case .MFree:
		return u64(syscall_mfree(a1)), 0
	case .InterruptVectorGet:
		interruptErr, vector, lapicID := syscall_interrupt_vector_get(a1)
		// Preserve the two-register syscall ABI. RDX contains the vector
		// in bits 0..7 and the destination LAPIC ID in bits 8..39.
		return u64(interruptErr), u64(vector) | (u64(lapicID) << 8)
	case .InterruptWait:
		return u64(syscall_interrupt_wait(a1)), 0
	case .MultiplexedMemoryCreate:
		err, handle := syscall_multiplexed_memory_create(a1, a2)
		return u64(err), handle
	case .MultiplexedMemoryRead:
		return u64(syscall_multiplexed_memory_read(a1, a2, a3, a4, a5)), 0
	case .MultiplexedMemoryWrite:
		return u64(syscall_multiplexed_memory_write(a1, a2, a3, a4, a5)), 0
	case .ProtDomainCreate:
		err, handle := syscall_prot_domain_create(a1, a2)
		return u64(err), handle
	case .ProtDomainEdit:
		return u64(syscall_prot_domain_edit(a1, a2, a3)), 0
	case .ProtDomainDestroy:
		return u64(syscall_prot_domain_destroy(a1)), 0
	case .ExecutionStart:
		return u64(syscall_execution_start(a1, a2, a3, a4, a5)), 0
	case .DebugPrint:
		// Debug-only: prints "dbg: <label>: <value> (0x<value>)" to the
		// serial log. a1/a2 are a (ptr, len) string read straight out of
		// adam's identity-mapped memory -- fine for a debug-only path, same
		// trust model as every other pointer adam hands the kernel. Compiled
		// out entirely in non -debug builds, and unreachable from userspace
		// there too (lib/syscalls only emits the caller-side stub under
		// ODIN_DEBUG).
		when ODIN_DEBUG {
			label := string(([^]u8)(uintptr(a1))[:a2])
			print.serial_write("dbg: ")
			print.serial_write(label)
			print.serial_write(": ")
			print.serial_write_u64(a3)
			print.serial_write(" (0x")
			print.serial_write_hex(a3)
			print.serial_writeln(")")
		}
	}
	return 0, 0
}

multiplexedMemoryLock: spinlock.Spinlock

syscall_multiplexed_memory_create :: proc "contextless" (
	phys, size: u64,
) -> (
	err: syscalls.MultiplexedMemoryError,
	handle: u64,
) {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission, 0
	}
	if size == 0 || phys + size < phys do return .InvalidRange, 0

	domain := cpu.rrCurrent.domain

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	resource, found := resource_find_exact(domain.resources[:], phys)
	if !found || resource.region.size != size {
		return .InvalidRange, 0
	}

	if .Volatile in resource.flags {
		kernelMMIOFlags := lmem.PageFlags{.Present, .Write, .PWT, .PCD, .NX}
		for page := phys; page < phys + size; page += shared.PAGE_SIZE {
			pmm.map_page(pmm.kernelPML4, page, page, ._4KB, kernelMMIOFlags)
		}
	}

	resource.flags += {.Multiplexed}
	for page := phys; page < phys + size; page += shared.PAGE_SIZE {
		pmm.unmap_page(domain.pml4, page)
	}
	return .None, phys
}

syscall_multiplexed_memory_read :: proc "contextless" (
	handle, offset, dest, size, width: u64,
) -> syscalls.MultiplexedMemoryError {
	return syscall_multiplexed_memory_access(handle, offset, dest, size, width, false)
}

syscall_multiplexed_memory_write :: proc "contextless" (
	handle, offset, source, size, width: u64,
) -> syscalls.MultiplexedMemoryError {
	return syscall_multiplexed_memory_access(handle, offset, source, size, width, true)
}

syscall_multiplexed_memory_access :: proc "contextless" (
	handle, offset, userPtr, size, width: u64,
	writeTarget: bool,
) -> syscalls.MultiplexedMemoryError {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission
	}
	if handle == 0 do return .InvalidHandle
	if width != 1 && width != 2 && width != 4 do return .InvalidWidth
	if size == 0 || size % width != 0 do return .InvalidRange
	if offset + size < offset do return .InvalidRange

	domain := cpu.rrCurrent.domain

	// resource is a pointer into domain.resources -- only safe to read while
	// domain.lock is held. Copy out everything needed below, then release.
	resourceFlags: MemoryResourceFlags
	resourceMemory: MemoryHandle
	resourceRegionPhys, resourceRegionSize: u64
	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		resource, found := resource_find_exact(domain.resources[:], handle)
		if !found || .Multiplexed not_in resource.flags do return .InvalidHandle
		resourceFlags = resource.flags
		resourceMemory = resource.memory
		resourceRegionPhys = resource.region.phys
		resourceRegionSize = resource.region.size
	}

	// memory_slot_get returns a pointer into the growable slot array. Keep it
	// only while the manager lock is held; copy the fields needed below.
	memoryPhys, memorySize: u64
	{
		spinlock.lock(&memoryManager.lock)
		defer spinlock.unlock(&memoryManager.lock)
		slot := memory_slot_get(resourceMemory)
		assert(slot != nil)
		if slot == nil {
			return .InvalidHandle
		}
		memoryPhys = slot.phys
		memorySize = slot.size
	}

	assert(memoryPhys == resourceRegionPhys)
	assert(memorySize == resourceRegionSize)
	if memoryPhys != resourceRegionPhys || memorySize != resourceRegionSize {
		return .InvalidHandle
	}
	if offset > resourceRegionSize || size > resourceRegionSize - offset do return .InvalidRange
	userBufferOK := pmm.user_range_accessible(domain.pml4, userPtr, size, write = !writeTarget)
	if !userBufferOK do return .InvalidBuffer

	spinlock.lock(&multiplexedMemoryLock)
	defer spinlock.unlock(&multiplexedMemoryLock)

	for pos in u64(0) ..< size {
		if pos % width != 0 do continue
		target := rawptr(uintptr(memoryPhys + offset + pos))
		user := rawptr(uintptr(userPtr + pos))
		if .Volatile in resourceFlags {
			switch width {
			case 1:
				if writeTarget {
					ah.mmio_write_u8(target, (^u8)(user)^)
				} else {
					(^u8)(user)^ = ah.mmio_read_u8(target)
				}
			case 2:
				if writeTarget {
					ah.mmio_write_u16(target, (^u16)(user)^)
				} else {
					(^u16)(user)^ = ah.mmio_read_u16(target)
				}
			case 4:
				if writeTarget {
					ah.mmio_write_u32(target, (^u32)(user)^)
				} else {
					(^u32)(user)^ = ah.mmio_read_u32(target)
				}
			}
		} else if writeTarget {
			mem.copy(target, user, int(width))
		} else {
			mem.copy(user, target, int(width))
		}
	}
	return .None
}
syscall_mmap :: proc "contextless" (
	count: u64,
	size: lmem.PageSize,
	flags: lmem.PageFlags,
) -> (
	err: syscalls.MMapError,
	phys: u64,
) {
	context = gKernelCtx
	if count == 0 do return .InvalidSize, 0

	pageBytes: u64
	switch size {
	case ._4KB:
		pageBytes = 4 * mem.Kilobyte
	case ._2MB:
		pageBytes = 2 * mem.Megabyte
	case ._1GB:
		pageBytes = mem.Gigabyte
	}
	if pageBytes == 0 do return .InvalidPageSize, 0
	if count > max(u64) / pageBytes do return .InvalidSize, 0
	totalBytes := count * pageBytes

	cpu := gs_read_cpustate()

	print.kassert(cpu != nil)
	print.kassert(cpu.rrCurrent != nil)
	print.kassert(cpu.rrCurrent.domain != nil)
	assert(cpu != nil)
	assert(cpu.rrCurrent != nil)
	assert(cpu.rrCurrent.domain != nil)

	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .InvalidSize, 0
	}
	domain := cpu.rrCurrent.domain
	assert(domain.resources != nil)

	// Present and PS are controlled by map_page. User is mandatory for this
	// syscall; the remaining flags are supplied by the caller.
	mapFlags := flags
	mapFlags -= {.Present, .PS}
	mapFlags += {.User}

	allocatedPhys := uintptr(pmm.alloc_zeroed(totalBytes))
	if allocatedPhys == 0 || allocatedPhys == max(uintptr) do return .OutOfMemory, 0

	for i in u64(0) ..< count {
		pmm.map_page(
			domain.pml4,
			u64(allocatedPhys) + i * pageBytes,
			u64(allocatedPhys) + i * pageBytes,
			size,
			mapFlags,
		)
	}
	if .Write in flags {
		pml4 := ([^]u64)(uintptr(domain.pml4))
		pml4e := pml4[(allocatedPhys >> 39) & 0x1FF]
		pdpt := ([^]u64)(uintptr(pml4e & 0x000F_FFFF_FFFF_F000))
		pdpte := pdpt[(allocatedPhys >> 30) & 0x1FF]
		pd := ([^]u64)(uintptr(pdpte & 0x000F_FFFF_FFFF_F000))
		pde := pd[(allocatedPhys >> 21) & 0x1FF]
		pt := ([^]u64)(uintptr(pde & 0x000F_FFFF_FFFF_F000))
		pte := pt[(allocatedPhys >> 12) & 0x1FF]
		print.serial_write("mmap ptes ")
		print.serial_write_hex(pml4e)
		print.serial_write(" ")
		print.serial_write_hex(pdpte)
		print.serial_write(" ")
		print.serial_write_hex(pde)
		print.serial_write(" ")
		print.serial_write_hex(pte)
		print.serial_writeln("")
	}

	resource: MemoryResource
	memory_resource_init(
		&resource,
		u64(allocatedPhys),
		totalBytes,
		size,
		mapFlags,
		{},
		.AllocatedRAM,
	)
	spinlock.rw_write_lock(&domain.lock)
	_, inserted := resource_insert(&domain.resources, resource)
	spinlock.rw_write_unlock(&domain.lock)
	if !inserted {
		for i in u64(0) ..< count {
			pmm.unmap_page(domain.pml4, u64(allocatedPhys) + i * pageBytes)
		}
		pmm.free_pages(u64(allocatedPhys), totalBytes)
		return .TrackingFailed, 0
	}

	return .None, u64(allocatedPhys)

}

syscall_mfree :: proc "contextless" (addr: u64) -> (err: syscalls.MFreeError) {
	context = gKernelCtx

	cpu := gs_read_cpustate()
	assert(cpu != nil)
	assert(cpu.rrCurrent != nil)
	assert(cpu.rrCurrent.domain != nil)
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .InvalidAddress
	}
	domain := cpu.rrCurrent.domain

	spinlock.rw_write_lock(&domain.lock)
	allocation, found := resource_remove(&domain.resources, addr)
	spinlock.rw_write_unlock(&domain.lock)
	if !found {
		return .InvalidAddress
	}

	memory_object_release(allocation.memory)
	return .None
}

MSI_VECTOR_FIRST :: 32
MSI_VECTOR_COUNT :: 208

syscall_interrupt_vector_get :: proc "contextless" (
	resourcePhys: u64,
) -> (
	err: syscalls.InterruptVectorGetError,
	vector: u64,
	lapicID: u32,
) {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission, 0, 0
	}

	domain := cpu.rrCurrent.domain
	isInterruptSource: bool
	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		resource, found := resource_find_exact(domain.resources[:], resourcePhys)
		isInterruptSource = found && .InterruptSource in resource.flags
	}
	if !isInterruptSource {
		return .NoPermission, 0, 0
	}

	{
		spinlock.lock(&interruptLock)
		defer spinlock.unlock(&interruptLock)

		for i in 0 ..< MSI_VECTOR_COUNT {
			v := MSI_VECTOR_FIRST + i
			if interruptExecutions[v] != nil do continue
			interruptExecutions[v] = cpu.rrCurrent
			return .None, u64(v), cpu.apicId
		}
	}

	return .NoVectors, 0, 0
}

syscall_interrupt_wait :: proc "contextless" (
	vectorRaw: u64,
) -> (
	err: syscalls.InterruptWaitError,
) {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission
	}
	if vectorRaw >= 256 do return .InvalidVector
	if cpu.syscallFrame == nil do return .NoPermission

	execution := cpu.rrCurrent
	vector := int(vectorRaw)

	{
		spinlock.lock(&interruptLock)
		defer spinlock.unlock(&interruptLock)

		if interruptExecutions[vector] != execution {
			return .NoPermission
		}
		if execution.schedulerState == .WaitingOnInterrupt {
			return .AlreadyWaiting
		}

		execution.state = cpu.syscallFrame^
		fxsave_asm(&execution.state.fxsave)
		execution.state.rax = u64(syscalls.InterruptWaitError.None)
		execution.state.rdx = 0
		execution.schedulerState = .WaitingOnInterrupt
		cpu.rrCurrent = nil
	}

	lapic_disable_deadline()
	run_abort(cpu.schedulerResumeRsp)
	return .None
}

syscall_prot_domain_create :: proc "contextless" (
	regionsPtr, count: u64,
) -> (
	err: syscalls.ProtDomainCreateError,
	handle: u64,
) {
	context = gKernelCtx

	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission, 0
	}

	callerDomain := cpu.rrCurrent.domain

	if count == 0 do return .InvalidRegionCount, 0
	regionBytes, overflowed := intrinsics.overflow_mul(count, size_of(syscalls.MemRegion))
	if overflowed do return .InvalidRegionCount, 0

	if !pmm.user_range_accessible(callerDomain.pml4, regionsPtr, regionBytes, write = false) {
		return .InvalidRegionCount, 0
	}

	regions: []syscalls.MemRegion = mem.slice_ptr(
		(^syscalls.MemRegion)(rawptr(uintptr(regionsPtr))),
		int(count),
	)

	{
		spinlock.rw_read_lock(&callerDomain.lock)
		defer spinlock.rw_read_unlock(&callerDomain.lock)
		for r in regions {
			if r.op != .Add do return .InvalidRegion, 0
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			if !found do return .NotOwned, 0
			if r.phys + r.size > owner.region.phys + owner.region.size do return .NotOwned, 0
			if r.flags - owner.region.flags != {} do return .NotOwned, 0
		}
	}

	newPml4 := pmm.alloc_zeroed(shared.PAGE_SIZE)
	if newPml4 == 0 do return .OutOfMemory, 0
	pmm.pml4_deep_copy(newPml4, pmm.kernelPML4, true)

	pd, allocErr := new(ProtectionDomain)
	if allocErr != nil {
		pmm.free_pages(newPml4, shared.PAGE_SIZE)
		return .OutOfMemory, 0
	}

	pd.pml4 = newPml4
	protdomain_register(pd)
	defer if err != .None do domain_destroy(pd)

	{
		// pd isn't reachable via any handle yet, so this is uncontended in
		// practice -- held anyway so every resources mutation goes through
		// the owning domain's lock the same way, with no special case here.
		spinlock.rw_write_lock(&pd.lock)
		defer spinlock.rw_write_unlock(&pd.lock)
		for r in regions {
			pmm.map_page(pd.pml4, r.phys, r.logical, r.pageSize, r.flags)
			resource: MemoryResource
			memory_resource_init(&resource, r.phys, r.size, r.pageSize, r.flags, {}, .AllocatedRAM)
			if _, ok := resource_insert(&pd.resources, resource); !ok do return .TrackingFailed, 0
		}
	}
	return .None, protdomain_handle_encode(pd)
}

syscall_prot_domain_edit :: proc "contextless" (
	handle, regionsPtr, count: u64,
) -> (
	err: syscalls.ProtDomainEditError,
) {
	context = gKernelCtx

	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission
	}

	callerDomain := cpu.rrCurrent.domain

	target := protdomain_handle_resolve(handle)
	if target == nil do return .InvalidHandle

	if count == 0 do return .InvalidRegionCount
	regionBytes, overflowed := intrinsics.overflow_mul(count, size_of(syscalls.MemRegion))
	if overflowed do return .InvalidRegionCount
	if !pmm.user_range_accessible(callerDomain.pml4, regionsPtr, regionBytes, write = false) {
		return .InvalidRegionCount
	}
	regions := mem.slice_ptr((^syscalls.MemRegion)(rawptr(uintptr(regionsPtr))), int(count))

	// Held across both passes below: pass 1's guarantees about target's (and,
	// for Add, callerDomain's) resources must still hold when pass 2 applies
	// them, and nothing else may mutate either domain's resources in between.
	// Collapses to one lock when editing your own domain (target ==
	// callerDomain), and locks in address order otherwise so two threads
	// editing the same pair of domains in opposite order can't deadlock.
	domains_write_lock(callerDomain, target)
	defer domains_write_unlock(callerDomain, target)

	// Pass 1: validate everything, mutate nothing.
	for r, i in regions {
		for j in i + 1 ..< len(regions) {
			other := regions[j]
			if r.phys == other.phys do return .InvalidRegion
			if r.op == .Add &&
			   other.op == .Add &&
			   resource_ranges_overlap(r.phys, r.size, other.phys, other.size) {
				return .InvalidRegion
			}
		}

		switch r.op {
		case .Add:
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			if !found do return .NotOwned
			if r.phys + r.size > owner.region.phys + owner.region.size do return .NotOwned
			if r.flags - owner.region.flags != {} do return .NotOwned
			if resource_overlap_existing(target.resources[:], r.phys, r.size) do return .InvalidRegion
		case .Delete:
			if _, found := resource_find_exact(target.resources[:], r.phys); !found do return .NotFound
		}
	}
	for r in regions {
		switch r.op {
		case .Add:
			pmm.map_page(target.pml4, r.phys, r.logical, r.pageSize, r.flags)
			resource: MemoryResource
			memory_resource_init(&resource, r.phys, r.size, r.pageSize, r.flags, {}, .AllocatedRAM)
			_, ok := resource_insert(&target.resources, resource)
			assert(ok)
		case .Delete:
			removed, found := resource_remove(&target.resources, r.phys)
			assert(found)
			pmm.unmap_page(target.pml4, removed.region.logical)
			memory_object_release(removed.memory)
		}
	}

	return .None
}

syscall_prot_domain_destroy :: proc "contextless" (
	handle: u64,
) -> (
	err: syscalls.ProtDomainDestroyError,
) {
	context = gKernelCtx
	pd := protdomain_handle_resolve(handle)
	if pd == nil do return .InvalidHandle
	domain_destroy(pd)
	return .None
}

syscall_execution_start :: proc "contextless" (
	handle, entryRip, entryRsp, arg0, arg1: u64,
) -> (
	err: syscalls.ExecutionStartError,
) {
	context = gKernelCtx

	domain := protdomain_handle_resolve(handle)
	if domain == nil do return .InvalidHandle
	if entryRip == 0 || entryRsp == 0 || entryRsp % 16 != 8 do return .InvalidEntry


	savedState := saved_state_fresh(entryRip, entryRsp)
	savedState.rdi = arg0
	savedState.rsi = arg1

	exec := execution_create(domain, savedState)
	if exec == nil do return .OutOfMemory

	idx := u32(intrinsics.atomic_add(&rrCpuNext, 1)) % u32(len(cpus))
	execution_enqueue(exec, &cpus[idx])

	return .None
}
