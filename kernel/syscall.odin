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
syscall_return_noncanonical :: proc "c" () -> ! {
	context = gKernelCtx
	assert(gs_read_cpustate().currentGrant.domain != nil)
	print.serial_writeln("syscall: non-canonical return rip, grant dropped")
	grant_exit()
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
	domain := gs_read_cpustate().currentGrant.domain
	assert(domain != nil)
	if size == 0 || phys + size < phys do return .InvalidRange, 0

	defer if err == .None do tlb_wait_domain_flushed(domain)
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
		domain_unmap_page(domain, page)
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
	domain := gs_read_cpustate().currentGrant.domain
	assert(domain != nil)
	if handle == 0 do return .InvalidHandle
	if width != 1 && width != 2 && width != 4 do return .InvalidWidth
	if size == 0 || size % width != 0 do return .InvalidRange
	if offset + size < offset do return .InvalidRange

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
	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		if !user_range_accessible(domain, userPtr, size, !writeTarget) do return .InvalidBuffer
	}

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
	domain := gs_read_cpustate().currentGrant.domain
	assert(domain != nil)
	if regionsCount == 0 do return .InvalidSize, 0

	regionsBytes, overflow := intrinsics.overflow_mul(regionsCount, size_of(syscalls.MMapRegion))
	if overflow do return .InvalidSize, 0

	regions, allocErr := make([]syscalls.MMapRegion, int(regionsCount))
	if allocErr != nil do return .OutOfMemory, 0
	defer delete(regions)
	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		if !user_range_accessible(domain, regionsPtr, regionsBytes, false) do return .InvalidSize, 0
		mem.copy(raw_data(regions), rawptr(uintptr(regionsPtr)), int(regionsBytes))
	}
	totalBytes: u64

	for r in regions {
		if r.count == 0 do return .InvalidSize, 0
		if r.pageSize != ._4KB do return .InvalidPageSize, 0
		pageBytes := syscalls.mmap_page_size_bytes(r.pageSize)
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
	underlay := memory_underlay_create(u64(allocatedPhys), totalBytes, .AllocatedRAM)
	for _ in 1 ..< len(regions) do memory_underlay_increment(underlay)

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

		resource := MemoryResource {
			overlay = {
				phys = regionPhys,
				logical = regionPhys,
				size = rBytes,
				pageSize = r.pageSize,
				flags = mapFlags,
			},
			underlay = underlay,
		}
		_, inserted := resource_insert(&domain.resources, resource)
		assert(inserted, "previous code should have ensured that insert goes on guaranteed")

		offset += rBytes
	}

	return .None, u64(allocatedPhys)


}

syscall_mfree :: proc "contextless" (addrsPtr, count: u64) -> (err: syscalls.MFreeError) {
	context = gKernelCtx
	domain := gs_read_cpustate().currentGrant.domain
	assert(domain != nil)
	if count == 0 do return .InvalidAddress

	addrsBytes, overflowed := intrinsics.overflow_mul(count, size_of(u64))
	if overflowed do return .InvalidAddress
	addrs, allocErr := make([]u64, int(count))
	if allocErr != nil do return .OutOfMemory
	defer delete(addrs)

	removed, removedErr := make([]MemoryResource, len(addrs))
	if removedErr != nil do return .OutOfMemory
	defer delete(removed)

	{
		spinlock.rw_write_lock(&domain.lock)
		defer spinlock.rw_write_unlock(&domain.lock)

		if !user_range_accessible(domain, addrsPtr, addrsBytes, false) do return .InvalidAddress
		mem.copy(raw_data(addrs), rawptr(uintptr(addrsPtr)), int(addrsBytes))

		for a, i in addrs {
			for j in i + 1 ..< len(addrs) {
				if addrs[j] == a do return .InvalidAddress
			}
			if _, found := resource_find_exact(domain.resources[:], a); !found do return .InvalidAddress
		}

		for a, i in addrs {
			r, _ := resource_remove(&domain.resources, a)
			removed[i] = r
			pageBytes := syscalls.mmap_page_size_bytes(r.overlay.pageSize)
			pageCount := r.overlay.size / pageBytes
			for j in u64(0) ..< pageCount {
				domain_unmap_page(domain, r.overlay.logical + j * pageBytes)
			}
		}
	}

	tlb_wait_domain_flushed(domain)
	for r in removed do memory_underlay_release(r.underlay)
	return .None
}

@(export)
syscall_dispatch :: proc "sysv" (nr, a1, a2, a3, a4, a5, a6: u64) -> (err: u64, r1: u64) {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	assert(cpu.currentGrant.domain != nil)
	defer if intrinsics.atomic_load(&cpu.currentGrant.weight) == 0 do grant_exit()

	switch syscalls.Syscall(nr) {
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

	case .GrantSpawn:
		return u64(syscall_grant_spawn(transmute(int)a1, a2, a3, a4, a5)), 0
	case .GrantEdit:
		return u64(syscall_grant_edit(transmute(int)a1, a2, a3)), 0

	case .DebugPrint:
		domain := cpu.currentGrant.domain
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		if !user_range_accessible(domain, a1, a2, false) do return max(u64), max(u64)

		label := string(([^]u8)(uintptr(a1))[:a2])
		spinlock.lock(&serialPrintLock)
		defer spinlock.unlock(&serialPrintLock)
		print.serial_write("dbg: ")
		print.serial_write(label)
		print.serial_write(": ")
		print.serial_write_u64(a3)
		print.serial_write(" (")
		print.serial_write_hex(a3)
		print.serial_writeln(")")
	}
	return max(u64), max(u64)
}
