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
syscall_dispatch :: proc "sysv" (nr, a1, a2, a3, a4, a5, a6: u64) -> (err: u64, r1: u64) {


	switch syscalls.Syscall(nr) {
	case .Exit:
		context = gKernelCtx
		spinlock.lock(&serialPrintLock)
		print.serial_write("exit code: ")
		print.serial_write_u64(a1)
		print.serial_writeln("")
		spinlock.unlock(&serialPrintLock)
		cpu := gs_read_cpustate()
		if cpu != nil do grant_stop_current(cpu, .Exit)
		run_abort()
	case .MMap:
		mmapErr, addr := syscall_mmap(a1, a2)
		return u64(mmapErr), addr
	case .MFree:
		return u64(syscall_mfree(a1, a2)), 0
	case .MultiplexedMemoryCreate:
		err, handle := syscall_multiplexed_memory_create(a1, a2)
		return u64(err), handle
	case .MultiplexedMemoryRead:
		return u64(syscall_multiplexed_memory_read(a1, a2, a3, a4, a5)), 0
	case .MultiplexedMemoryWrite:
		return u64(syscall_multiplexed_memory_write(a1, a2, a3, a4, a5)), 0
	case .ProtDomainCreate:
		err, handle := syscall_prot_domain_create((^byte)(uintptr(a1)), a2, a3)
		return u64(err), transmute(u64)handle
	case .ProtDomainEdit:
		return u64(syscall_prot_domain_edit(transmute(int)a1, a2, a3, a4)), 0
	case .ProtDomainDestroy:
		return u64(syscall_prot_domain_destroy(transmute(int)a1)), 0

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
	return max(u64), max(u64)
}

@(export)
syscall_return_noncanonical :: proc "c" () -> ! {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	assert(cpu != nil)
	assert(cpu.currentGrant.domain != nil)
	print.serial_writeln("syscall: non-canonical return rip, grant dropped")
	grant_stop_current(cpu, .Exit)
	run_abort()
}

multiplexedMemoryLock: spinlock.Spinlock
serialPrintLock: spinlock.Spinlock

syscall_multiplexed_memory_create :: proc "contextless" (
	phys, size: u64,
) -> (
	err: syscalls.MultiplexedMemoryError,
	handle: u64,
) {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil {
		return .NoPermission, 0
	}
	if size == 0 || phys + size < phys do return .InvalidRange, 0

	domain := cpu.currentGrant.domain

	kernel_switch_cr3()
	defer domain_switch_cr3(domain)

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	resource, found := resource_find_exact(domain.resources[:], phys)
	if !found || resource.overlay.size != size {
		return .InvalidRange, 0
	}

	if .Volatile in resource.overlayFlags {
		kernelMMIOFlags := lmem.PageFlags{.Present, .Write, .PWT, .PCD, .NX}
		for page := phys; page < phys + size; page += shared.PAGE_SIZE {
			pmm.map_page(pmm.kernelPML4, page, page, ._4KB, kernelMMIOFlags)
		}
	}

	resource.overlayFlags += {.Multiplexed}
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
	if cpu == nil || cpu.currentGrant.domain == nil {
		return .NoPermission
	}
	if handle == 0 do return .InvalidHandle
	if width != 1 && width != 2 && width != 4 do return .InvalidWidth
	if size == 0 || size % width != 0 do return .InvalidRange
	if offset + size < offset do return .InvalidRange

	domain := cpu.currentGrant.domain

	// resource is a pointer into domain.resources -- only safe to read while
	// domain.lock is held. Copy out everything needed below, then release.
	resourceFlags: MemoryResourceFlags
	resourceMemory: ^MemoryUnderlay
	resourceRegionPhys, resourceRegionSize: u64
	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		resource, found := resource_find_exact(domain.resources[:], handle)
		if !found || .Multiplexed not_in resource.overlayFlags do return .InvalidHandle
		resourceFlags = resource.overlayFlags
		resourceMemory = resource.underlay
		resourceRegionPhys = resource.overlay.phys
		resourceRegionSize = resource.overlay.size
	}

	memoryPhys, memorySize: u64
	{
		spinlock.lock(&memoryUnderlaysLock)
		defer spinlock.unlock(&memoryUnderlaysLock)
		memoryPhys = resourceMemory.phys
		memorySize = resourceMemory.size
	}

	assert(memoryPhys == resourceRegionPhys)
	assert(memorySize == resourceRegionSize)
	if memoryPhys != resourceRegionPhys || memorySize != resourceRegionSize {
		return .InvalidHandle
	}
	if offset > resourceRegionSize || size > resourceRegionSize - offset do return .InvalidRange
	userBufferOK := pmm.user_range_accessible(domain.pml4, userPtr, size, write = !writeTarget)
	if !userBufferOK do return .InvalidBuffer

	// Copy the whole user buffer into a kernel-owned bounce buffer right after
	// validation, and never touch userPtr again below. Otherwise the loop
	// below would keep re-dereferencing userPtr while doing (potentially
	// slow) device I/O, giving another execution a wide window to unmap or
	// free that memory out from under it.
	buf, allocErr := make([]u8, int(size))
	if allocErr != nil do return .OutOfMemory
	defer delete(buf)

	kernel_switch_cr3()
	defer domain_switch_cr3(domain)

	if writeTarget {
		mem.copy(raw_data(buf), rawptr(uintptr(userPtr)), int(size))
	}

	spinlock.lock(&multiplexedMemoryLock)
	defer spinlock.unlock(&multiplexedMemoryLock)

	for pos in u64(0) ..< size {
		if pos % width != 0 do continue
		target := rawptr(uintptr(memoryPhys + offset + pos))
		bufPos := rawptr(uintptr(uintptr(raw_data(buf)) + uintptr(pos)))
		if .Volatile in resourceFlags {
			switch width {
			case 1:
				if writeTarget {
					ah.mmio_write_u8(target, (^u8)(bufPos)^)
				} else {
					(^u8)(bufPos)^ = ah.mmio_read_u8(target)
				}
			case 2:
				if writeTarget {
					ah.mmio_write_u16(target, (^u16)(bufPos)^)
				} else {
					(^u16)(bufPos)^ = ah.mmio_read_u16(target)
				}
			case 4:
				if writeTarget {
					ah.mmio_write_u32(target, (^u32)(bufPos)^)
				} else {
					(^u32)(bufPos)^ = ah.mmio_read_u32(target)
				}
			}
		} else if writeTarget {
			mem.copy(target, bufPos, int(width))
		} else {
			mem.copy(bufPos, target, int(width))
		}
	}

	if !writeTarget {
		mem.copy(rawptr(uintptr(userPtr)), raw_data(buf), int(size))
	}
	return .None
}
syscall_mmap :: proc "contextless" (
	regionsPtr: u64,
	regionsCount: u64,
) -> (
	err: syscalls.MMapError,
	phys: u64,
) {
	context = gKernelCtx
	if regionsCount == 0 do return .InvalidSize, 0

	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil {
		return .InvalidSize, 0
	}
	domain := cpu.currentGrant.domain

	regionsBytes, overflow := intrinsics.overflow_mul(regionsCount, size_of(syscalls.MMapRegion))
	if overflow do return .InvalidSize, 0

	if !pmm.user_range_accessible(domain.pml4, regionsPtr, regionsBytes, write = false) {
		return .InvalidSize, 0
	}
	regions, allocErr := make([]syscalls.MMapRegion, int(regionsCount))
	if allocErr != nil do return .OutOfMemory, 0
	defer delete(regions)
	mem.copy(raw_data(regions), rawptr(uintptr(regionsPtr)), int(regionsBytes))
	totalBytes: u64

	for r in regions {
		if r.count == 0 do return .InvalidSize, 0
		pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
		if pageBytes == 0 do return .InvalidPageSize, 0
		rBytes, ov1 := intrinsics.overflow_mul(r.count, pageBytes)
		if ov1 do return .InvalidPageSize, 0
		newTotal, ov2 := intrinsics.overflow_add(totalBytes, rBytes)
		if ov2 do return .InvalidPageSize, 0
		totalBytes = newTotal
	}
	if totalBytes == 0 do return .InvalidSize, 0

	allocatedPhys := uintptr(pmm.alloc_zeroed(totalBytes))
	if allocatedPhys == 0 || allocatedPhys == max(uintptr) do return .OutOfMemory, 0

	defer if err != .None do pmm.free_pages(u64(allocatedPhys), totalBytes)

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	when ODIN_DEBUG {
		assert(!resource_overlaps(domain.resources[:], u64(allocatedPhys), totalBytes))
	}


	if reserve(&domain.resources, len(domain.resources) + len(regions)) != nil do return .OutOfMemory, 0

	// Everything above is validated: range is free, capacity is reserved.
	// Nothing below can fail.
	offset: u64 = 0
	for r in regions {
		pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
		rBytes := r.count * pageBytes
		regionPhys := u64(allocatedPhys) + offset

		mapFlags := r.flags
		mapFlags -= {.Present, .PS}
		mapFlags += {.User}

		for i in u64(0) ..< r.count {
			pmm.map_page(
				domain.pml4,
				regionPhys + i * pageBytes,
				regionPhys + i * pageBytes,
				r.pageSize,
				mapFlags,
			)
		}

		resource := resource_init(regionPhys, rBytes, r.pageSize, mapFlags, {}, .AllocatedRAM)
		_, inserted := resource_insert(&domain.resources, resource)
		assert(inserted, "previous code should have ensured that insert goes on guaranteed")

		offset += rBytes
	}

	return .None, u64(allocatedPhys)


}

syscall_mfree :: proc "contextless" (addrsPtr, count: u64) -> (err: syscalls.MFreeError) {
	context = gKernelCtx
	if count == 0 do return .InvalidAddress

	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil {
		return .InvalidAddress
	}
	domain := cpu.currentGrant.domain

	addrsBytes, overflowed := intrinsics.overflow_mul(count, size_of(u64))
	if overflowed do return .InvalidAddress
	if !pmm.user_range_accessible(domain.pml4, addrsPtr, addrsBytes, write = false) {
		return .InvalidAddress
	}
	addrs, allocErr := make([]u64, int(count))
	if allocErr != nil do return .OutOfMemory
	defer delete(addrs)
	mem.copy(raw_data(addrs), rawptr(uintptr(addrsPtr)), int(addrsBytes))

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	// Pass 1: validate everything, mutate nothing.
	for a, i in addrs {
		for j in i + 1 ..< len(addrs) {
			if addrs[j] == a do return .InvalidAddress // duplicate -- second free would spuriously "not found"
		}
		if _, found := resource_find_exact(domain.resources[:], a); !found do return .InvalidAddress
	}

	// Pass 2: nothing above can fail, so this can't fail partway through.

	removed := make([]MemoryResource, len(addrs))
	defer delete(removed)

	for a, i in addrs {
		r, _ := resource_remove(&domain.resources, a)
		removed[i] = r
		pageBytes := syscalls.mmap_page_size_bytes(r.overlay.pageSize)
		pageCount := r.overlay.size / pageBytes
		for j in u64(0) ..< pageCount {
			pmm.unmap_page(domain.pml4, r.overlay.logical + j * pageBytes)
		}
	}

	if domain.pcid != 0 do tlb_shootdown(domain.pcid)

	for r in removed {
		memory_underlay_release(r.underlay)
	}
	return .None
}

syscall_prot_domain_create :: proc "contextless" (
	authorityPtr: ^byte,
	regionsPtr, count: u64,
) -> (
	err: syscalls.ProtDomainCreateError,
	handle: int,
) {
	context = gKernelCtx

	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil {
		return .NoPermission, 0
	}
	if authorityPtr == nil do return .NoPermission, 0

	callerDomain := cpu.currentGrant.domain
	if !pmm.user_range_accessible(callerDomain.pml4, u64(uintptr(authorityPtr)), 1, write = true) {
		return .NoPermission, 0
	}

	if count == 0 do return .InvalidRegionCount, 0
	regionBytes, overflowed := intrinsics.overflow_mul(count, size_of(syscalls.MemRegion))
	if overflowed do return .InvalidRegionCount, 0

	if !pmm.user_range_accessible(callerDomain.pml4, regionsPtr, regionBytes, write = false) {
		return .InvalidRegionCount, 0
	}

	regions, regionsAllocErr := make([]syscalls.MemRegion, int(count))
	if regionsAllocErr != nil do return .OutOfMemory, 0
	defer delete(regions)
	mem.copy(raw_data(regions), rawptr(uintptr(regionsPtr)), int(regionBytes))

	{
		spinlock.rw_read_lock(&callerDomain.lock)
		defer spinlock.rw_read_unlock(&callerDomain.lock)
		for r in regions {
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			if !found do return .NotOwned, 0
			if r.phys + r.size > owner.overlay.phys + owner.overlay.size do return .NotOwned, 0
			if r.flags - owner.overlay.flags != {} do return .NotOwned, 0
		}
	}

	pd, pdIdx, allocErr := protdomain_new(authorityPtr)
	if allocErr != {} do return .OutOfMemory, 0
	defer if err != .None do protdomain_destroy(pdIdx)

	{
		// pd isn't reachable via any handle yet, so this is uncontended in
		// practice -- held anyway so every resources mutation goes through
		// the owning domain's lock the same way, with no special case here.
		spinlock.rw_write_lock(&pd.lock)
		defer spinlock.rw_write_unlock(&pd.lock)
		for r in regions {
			// Re-fetch the owner instead of trusting the earlier validation
			// pass: that pass ran under a since-released lock, so the
			// resource could have been mfree'd by now. Sharing owner.underlay
			// (rather than minting a fresh handle, like resource_init would)
			// ties this range's lifetime to the original allocation instead
			// of creating a second, independent owner of the same physical
			// pages -- see prot_domain_edit's .Add case, which does the same.
			spinlock.rw_read_lock(&callerDomain.lock)
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			ownerMemory: ^MemoryUnderlay
			if found do ownerMemory = owner.underlay
			spinlock.rw_read_unlock(&callerDomain.lock)
			if !found do return .NotOwned, 0

			pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
			pageCount := r.size / pageBytes
			for i in u64(0) ..< pageCount {
				pmm.map_page(
					pd.pml4,
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
				underlay = ownerMemory,
			}
			memory_underlay_increment(ownerMemory)
			defer if err != .None do memory_underlay_release(ownerMemory)

			if _, ok := resource_insert(&pd.resources, resource); !ok do return .TrackingFailed, 0
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

	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil {
		return .NoPermission
	}

	if opRaw != u64(syscalls.MemRegionOp.Add) && opRaw != u64(syscalls.MemRegionOp.Delete) {
		return .InvalidOp
	}
	op := syscalls.MemRegionOp(opRaw)

	callerDomain := cpu.currentGrant.domain

	spinlock.rw_read_lock(&protDomainPool.rwLock)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock)
	target, targetErr := protdomain_resolve_target_RUN_ON_LOCK(handle, callerDomain)
	if targetErr == .InvalidHandle do return .InvalidHandle
	if targetErr == .NoPermission do return .NoPermission

	if count == 0 do return .InvalidRegionCount
	regionBytes, overflowed := intrinsics.overflow_mul(count, size_of(syscalls.MemRegion))
	if overflowed do return .InvalidRegionCount
	if !pmm.user_range_accessible(callerDomain.pml4, regionsPtr, regionBytes, write = false) {
		return .InvalidRegionCount
	}
	regions, allocErr := make([]syscalls.MemRegion, int(count))
	if allocErr != nil do return .OutOfMemory
	defer delete(regions)
	mem.copy(raw_data(regions), rawptr(uintptr(regionsPtr)), int(regionBytes))

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
			if op == .Add && resource_ranges_overlap(r.phys, r.size, other.phys, other.size) {
				return .InvalidRegion
			}
		}

		switch op {
		case .Add:
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			if !found do return .NotOwned
			if r.phys + r.size > owner.overlay.phys + owner.overlay.size do return .NotOwned
			if r.flags - owner.overlay.flags != {} do return .NotOwned
			if resource_overlaps(target.resources[:], r.phys, r.size) do return .InvalidRegion
		case .Delete:
			if _, found := resource_find_exact(target.resources[:], r.phys); !found do return .NotFound
		}
	}
	for r in regions {
		switch op {
		case .Add:
			owner, found := resource_find_containing(callerDomain.resources[:], r.phys)
			if !found do return .NotOwned

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
			defer if err != .None {
				for i in u64(0) ..< pageCount {
					pmm.unmap_page(target.pml4, r.logical + i * pageBytes)
				}
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
			defer if err != .None do memory_underlay_release(owner.underlay)

			if _, ok := resource_insert(&target.resources, resource); !ok do return .TrackingFailed

		case .Delete:
			removed, found := resource_remove(&target.resources, r.phys)
			if !found do return .NotFound
			pageBytes := syscalls.mmap_page_size_bytes(removed.overlay.pageSize)
			pageCount := removed.overlay.size / pageBytes
			for i in u64(0) ..< pageCount {
				pmm.unmap_page(target.pml4, removed.overlay.logical + i * pageBytes)
			}
			if target.pcid != 0 do tlb_shootdown(target.pcid)
			memory_underlay_release(removed.underlay)

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

	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil {
		return .InvalidHandle
	}

	callerDomain := cpu.currentGrant.domain
	spinlock.rw_read_lock(&protDomainPool.rwLock)
	pd, targetErr := protdomain_resolve_target_RUN_ON_LOCK(handle, callerDomain)
	spinlock.rw_read_unlock(&protDomainPool.rwLock)
	if targetErr != .None do return .InvalidHandle
	if pd == callerDomain do return .InvalidHandle
	protdomain_destroy(handle)
	return .None
}
