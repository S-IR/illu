package kernel
import "../lib/lmem"
import "../lib/syscalls"
import "core:mem"
import "pmm"
import "print"
@(export)
syscall_dispatch :: proc "c" (nr, a1, a2, a3, a4, a5: u64) -> (err: syscalls.Error, r1: u64) {
	#partial switch syscalls.Syscall(nr) {
	case .Exit:
		print.serial_write("exit code: ")
		print.serial_write_u64(a1)
		print.serial_writeln("")
		exec_exit_current()
	case .MMap:
		count := a1
		if count == 0 do return .MMapInvalidSize, 0

		if a2 >= len(lmem.PageSize) do return .MMapInvalidPageSize, 0
		pageSize := transmute(lmem.PageSize)a2

		pageFlags := transmute(lmem.PageFlags)a3
		pageFlags += {.User}

		return syscall_mmap(count, pageSize, pageFlags)
	case .MFree:
		return syscall_mfree(a1), 0
	}
	return .None, 0
}
syscall_mmap :: proc "contextless" (
	count: u64,
	size: lmem.PageSize,
	flags: lmem.PageFlags,
) -> (
	err: syscalls.Error,
	phys: u64,
) {
	context = gKernelCtx
	if count == 0 do return .MMapInvalidSize, 0

	pageBytes: u64
	switch size {
	case ._4KB:
		pageBytes = 4 * mem.Kilobyte
	case ._2MB:
		pageBytes = 2 * mem.Megabyte
	case ._1GB:
		pageBytes = mem.Gigabyte
	}
	if pageBytes == 0 do return .MMapInvalidPageSize, 0
	if count > max(u64) / pageBytes do return .MMapInvalidSize, 0
	totalBytes := count * pageBytes

	cpu := gs_read_cpustate()

	print.kassert(cpu != nil)
	print.kassert(cpu.rrCurrent != nil)
	print.kassert(cpu.rrCurrent.domain != nil)
	assert(cpu != nil)
	assert(cpu.rrCurrent != nil)
	assert(cpu.rrCurrent.domain != nil)

	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .MMapInvalidSize, 0
	}
	domain := cpu.rrCurrent.domain
	assert(domain.allocs != nil)
	if domain.allocs == nil {
		return .MMapTrackingFailed, 0
	}

	// Present and PS are controlled by map_page. User is mandatory for this
	// syscall; the remaining flags are supplied by the caller.
	mapFlags := flags
	mapFlags -= {.Present, .PS}
	mapFlags += {.User}

	allocatedPhys := uintptr(pmm.alloc_pages(totalBytes))
	if allocatedPhys == 0 || allocatedPhys == max(uintptr) do return .MMapOutOfMemory, 0

	for i in u64(0) ..< count {
		pmm.map_page(domain.pml4, u64(allocatedPhys) + i * pageBytes, size, mapFlags)
	}
	_, allocation, inserted, allocErr := map_entry(&domain.allocs, allocatedPhys)
	if allocErr != nil {
		pmm.free_pages(u64(allocatedPhys), totalBytes)
		return .MMapTrackingFailed, 0
	}
	if !inserted {
		pmm.free_pages(u64(allocatedPhys), totalBytes)
		return .MMapTrackingFailed, 0
	}

	allocation^ = {
		sizeBytes = totalBytes,
		pageFlags = mapFlags,
		pageSize  = size,
	}

	return .None, u64(allocatedPhys)

}

syscall_mfree :: proc "contextless" (addr: u64) -> (err: syscalls.Error) {
	context = gKernelCtx

	cpu := gs_read_cpustate()
	assert(cpu != nil)
	assert(cpu.rrCurrent != nil)
	assert(cpu.rrCurrent.domain != nil)
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .MFreeInvalidAddress
	}
	domain := cpu.rrCurrent.domain

	if domain.allocs == nil {
		return .MFreeInvalidAddress
	}

	allocation, found := domain.allocs[uintptr(addr)]
	if !found {
		return .MFreeInvalidAddress
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
