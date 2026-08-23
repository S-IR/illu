package kernel
import "../lib/lmem"
import "../lib/syscalls"
import "../lib/spinlock"
import "../lib/shared"
import ah "../asm_helpers"
import "core:mem"
import "pmm"
import "print"
@(export)
// syscall_entry normalizes the Linux x86-64 syscall ABI into this System V call:
// (nr, a1, a2, a3, a4, a5) -> (rax error, rdx secondary result).
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
	}
	return 0, 0
}

multiplexedMemoryLock: spinlock.Spinlock

syscall_multiplexed_memory_create :: proc "contextless" (
	phys, size: u64,
) -> (err: syscalls.MultiplexedMemoryError, handle: u64) {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission, 0
	}
	if size == 0 || phys + size < phys do return .InvalidRange, 0

	domain := cpu.rrCurrent.domain
	resource, found := domain.resources[uintptr(phys)]
	if !found || resource.phys != phys || resource.size != size {
		return .InvalidRange, 0
	}

	if .Volatile in resource.flags {
		kernelMMIOFlags := lmem.PageFlags{.Present, .Write, .PWT, .PCD, .NX}
		for page := phys; page < phys + size; page += shared.PAGE_SIZE {
			pmm.map_page(pmm.kernelPML4, page, ._4KB, kernelMMIOFlags)
		}
	}

	resource.flags += {.Multiplexed}
	domain.resources[uintptr(phys)] = resource
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
	handle, offset, userPtr, size, width: u64, writeTarget: bool,
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

	resource, found := cpu.rrCurrent.domain.resources[uintptr(handle)]
	if !found || .Multiplexed not_in resource.flags do return .InvalidHandle
	if offset > resource.size || size > resource.size - offset do return .InvalidRange
	userBufferOK := pmm.user_range_accessible(
		cpu.rrCurrent.domain.pml4,
		userPtr,
		size,
		write = !writeTarget,
	)
	if !userBufferOK do return .InvalidBuffer

	spinlock.lock(&multiplexedMemoryLock)
	defer spinlock.unlock(&multiplexedMemoryLock)

	for pos in u64(0) ..< size {
		if pos % width != 0 do continue
		target := rawptr(uintptr(resource.phys + offset + pos))
		user := rawptr(uintptr(userPtr + pos))
		if .Volatile in resource.flags {
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
	if domain.resources == nil {
		return .TrackingFailed, 0
	}

	// Present and PS are controlled by map_page. User is mandatory for this
	// syscall; the remaining flags are supplied by the caller.
	mapFlags := flags
	mapFlags -= {.Present, .PS}
	mapFlags += {.User}

	allocatedPhys := uintptr(pmm.alloc_pages(totalBytes))
	if allocatedPhys == 0 || allocatedPhys == max(uintptr) do return .OutOfMemory, 0

	for i in u64(0) ..< count {
		pmm.map_page(domain.pml4, u64(allocatedPhys) + i * pageBytes, size, mapFlags)
	}
	_, allocation, inserted, allocErr := map_entry(&domain.resources, allocatedPhys)
	if allocErr != nil {
		pmm.free_pages(u64(allocatedPhys), totalBytes)
		return .TrackingFailed, 0
	}
	if !inserted {
		pmm.free_pages(u64(allocatedPhys), totalBytes)
		return .TrackingFailed, 0
	}

	allocation^ = {
		phys      = u64(allocatedPhys),
		size      = totalBytes,
		pageFlags = mapFlags,
		pageSize  = size,
		flags     = {.OwnedByDomain},
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

	if domain.resources == nil {
		return .InvalidAddress
	}

	allocation, found := domain.resources[uintptr(addr)]
	if !found || .OwnedByDomain not_in allocation.flags {
		return .InvalidAddress
	}

	pageBytes: u64
	switch allocation.pageSize {
	case ._4KB:
		pageBytes = 4 * mem.Kilobyte
	case ._2MB:
		pageBytes = 2 * mem.Megabyte
	case ._1GB:
		pageBytes = mem.Gigabyte
	}


	pmm.free_pages(addr, allocation.size)
	delete_key(&domain.resources, uintptr(addr))

	_, aErr := shrink(&domain.resources)
	assert(aErr == nil)
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
	resource, found := domain.resources[uintptr(resourcePhys)]
	if !found || .InterruptSource not_in resource.flags {
		return .NoPermission, 0, 0
	}

	{
		spinlock.lock(&interruptLock)
		defer spinlock.unlock(&interruptLock)

		for i in 0 ..< MSI_VECTOR_COUNT {
			vector := MSI_VECTOR_FIRST + i
			if interruptExecutions[vector] != nil do continue
			interruptExecutions[vector] = cpu.rrCurrent
			return .None, u64(vector), cpu.apicId
		}
	}

	return .NoVectors, 0, 0
}

syscall_interrupt_wait :: proc "contextless" (vectorRaw: u64) -> (err: syscalls.InterruptWaitError) {
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
