package alloc

import "../../kernel/pmm"
import "../lmem"
import "../shared"
import "../syscalls"
import "core:mem"

KERNEL_BUILD :: #config(KERNEL_BUILD, false)

// The allocator core asks for whole 4 KiB pages. Both backends intentionally
// expose the same address/count interface; only the implementation differs.
backend_alloc_pages :: proc(count: u64) -> u64 {
	if count == 0 || count > max(u64) / u64(shared.PAGE_SIZE) {
		return 0
	}

	when KERNEL_BUILD {
		phys := pmm.alloc_pages(count * u64(shared.PAGE_SIZE))
		if phys == 0 do return 0
		return u64(uintptr(pmm.phys_to_ptr(phys)))
	} else {
		regions := [1]syscalls.MMapRegion {
			{pageSize = lmem.PageSize._4KB, count = count, flags = {.Present, .Write}},
		}
		err, addr := syscalls.syscall_mmap_userspace(regions[:])
		if err != .None || addr == nil {
			return 0
		}
		return u64(uintptr(addr))
	}
}

backend_free_pages :: proc(addr, count: u64) {
	if addr == 0 || count == 0 {
		return
	}

	when KERNEL_BUILD {
		pmm.free_pages(pmm.ptr_to_phys(rawptr(uintptr(addr))), count * u64(shared.PAGE_SIZE))
	} else {
		_ = syscalls.mem_free_userspace(addr)
	}
}
when !KERNEL_BUILD {
	@(require_results)
	dma_pages :: proc(count: u64) -> (base: u64, err: shared.Error) {
		assert(count > 0)
		regions := [1]syscalls.MMapRegion{{pageSize = ._4KB, count = count, flags = {.Write, .NX}}}
		mmapErr, addr := syscalls.syscall_mmap_userspace(regions[:])
		if mmapErr != .None do return 0, .OutOfMemory
		assert(addr != nil)
		assert(u64(uintptr(addr)) % shared.PAGE_SIZE == 0)
		mem.zero(addr, int(count * shared.PAGE_SIZE))
		return u64(uintptr(addr)), .None
	}
}
