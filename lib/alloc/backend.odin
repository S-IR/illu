package alloc

import "../lmem"
import "../shared"
import "../syscalls"
import "../../kernel/pmm"

KERNEL_BUILD :: #config(KERNEL_BUILD, false)

// The allocator core asks for whole 4 KiB pages. Both backends intentionally
// expose the same address/count interface; only the implementation differs.
backend_alloc_pages :: proc(count: u64) -> u64 {
	if count == 0 || count > max(u64) / u64(shared.PAGE_SIZE) {
		return max(u64)
	}

	when KERNEL_BUILD {
		return pmm.alloc_pages(count * u64(shared.PAGE_SIZE))
	} else {
		err, addr := syscalls.syscall_mmap_userspace(
			count,
			lmem.PageSize._4KB,
			{.Present, .Write},
		)
		if err != .None || addr == nil {
			return max(u64)
		}
		return u64(uintptr(addr))
	}
}

backend_free_pages :: proc(addr, count: u64) {
	if addr == 0 || count == 0 {
		return
	}

	when KERNEL_BUILD {
		pmm.free_pages(addr, count * u64(shared.PAGE_SIZE))
	} else {
		_ = syscalls.syscall_mfree_userspace(addr)
	}
}
