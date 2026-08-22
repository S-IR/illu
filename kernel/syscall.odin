package kernel
import "../lib/lmem"
import "../lib/syscalls"
import "../lib/spinlock"
import "core:mem"
import "pmm"
import "print"
@(export)
syscall_dispatch :: proc "c" (nr, a1, a2, a3, a4, a5: u64) -> (err: u64, r1: u64) {
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
		interruptErr, vector := syscall_interrupt_vector_get(a1)
		return u64(interruptErr), vector
	case .InterruptWait:
		return u64(syscall_interrupt_wait(a1)), 0
	}
	return 0, 0
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
	assert(domain.allocs != nil)
	if domain.allocs == nil {
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
	_, allocation, inserted, allocErr := map_entry(&domain.allocs, allocatedPhys)
	if allocErr != nil {
		pmm.free_pages(u64(allocatedPhys), totalBytes)
		return .TrackingFailed, 0
	}
	if !inserted {
		pmm.free_pages(u64(allocatedPhys), totalBytes)
		return .TrackingFailed, 0
	}

	allocation^ = {
		sizeBytes = totalBytes,
		pageFlags = mapFlags,
		pageSize  = size,
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

	if domain.allocs == nil {
		return .InvalidAddress
	}

	allocation, found := domain.allocs[uintptr(addr)]
	if !found {
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


	pmm.free_pages(addr, allocation.sizeBytes)
	delete_key(&domain.allocs, uintptr(addr))

	_, aErr := shrink(&domain.allocs)
	assert(aErr == nil)
	return .None
}

MSI_VECTOR_FIRST :: 32
MSI_VECTOR_COUNT :: 208

syscall_interrupt_vector_get :: proc "contextless" (
	pciAddrRaw: u64,
) -> (
	err: syscalls.InterruptVectorGetError,
	vector: u64,
) {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission, 0
	}

	domain := cpu.rrCurrent.domain
	if domain.devices == nil do return .NoPermission, 0

	wanted := transmute(PCIAddress)pciAddrRaw
	hasDevice := false
	for device in domain.devices {
		if device == wanted {
			hasDevice = true
			break
		}
	}
	if !hasDevice do return .NoPermission, 0

	{
		spinlock.lock(&interruptLock)
		defer spinlock.unlock(&interruptLock)

		for i in 0 ..< MSI_VECTOR_COUNT {
			vector := MSI_VECTOR_FIRST + i
			if interruptExecutions[vector] != nil do continue
			interruptExecutions[vector] = cpu.rrCurrent
			return .None, u64(vector)
		}
	}

	return .NoVectors, 0
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
