package alloc

import "../../kernel/pmm"
import "../lmem"
import "../shared"
import "../syscalls"
import "core:mem"

KERNEL_BUILD :: #config(KERNEL_BUILD, false)

// The allocator core asks for whole 4 KiB pages. Both backends intentionally
// expose the same address/count interface; only the implementation differs.
backend_alloc_pages :: proc(pmmState: ^pmm.PMM, count: u64) -> u64 {
	if count == 0 || count > max(u64) / u64(shared.PAGE_SIZE) {
		return 0
	}

	when KERNEL_BUILD {
		assert(pmmState != nil)
		phys := pmm.alloc_pages(pmmState, count * u64(shared.PAGE_SIZE))
		if phys == 0 do return 0
		return u64(uintptr(pmm.phys_to_ptr(phys)))
	} else {
		regions := [1]syscalls.MMapRegion {
			{pageSize = lmem.PageSize._4KB, count = count, flags = {.Present, .Write}},
		}
		addr, err := syscalls.syscall_mmap_userspace(regions[:])
		if err != .None || addr == nil {
			return 0
		}
		return u64(uintptr(addr))
	}
}

backend_free_pages :: proc(pmmState: ^pmm.PMM, addr, count: u64) {
	if addr == 0 || count == 0 {
		return
	}

	when KERNEL_BUILD {
		assert(pmmState != nil)
		pmm.free_pages(pmmState, pmm.ptr_to_phys(rawptr(uintptr(addr))), count * u64(shared.PAGE_SIZE))
	} else {
		_ = syscalls.mem_free_userspace(addr)
	}
}
