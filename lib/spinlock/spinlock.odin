package spinlock
import "base:intrinsics"

KERNEL_BUILD :: #config(KERNEL_BUILD, false)

Spinlock :: struct {
	locked: u32,
}

when KERNEL_BUILD && !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		lock_asm :: proc(l: rawptr) ---
		unlock_asm :: proc(l: rawptr) ---
	}

	lock :: proc "contextless" (l: ^Spinlock) {
		lock_asm(rawptr(&l.locked))
	}

	unlock :: proc "contextless" (l: ^Spinlock) {
		unlock_asm(rawptr(&l.locked))
	}
} else {
	lock :: #force_inline proc "contextless" (l: ^Spinlock) {
		for intrinsics.atomic_compare_exchange_strong(&l.locked, 0, 1) != 0 {
			intrinsics.cpu_relax()
		}
	}

	unlock :: #force_inline proc "contextless" (l: ^Spinlock) {
		intrinsics.atomic_store(&l.locked, u32(0))
	}
}

RWLock :: struct {
	state: u32, // bit 31 = writer held; bits 0-30 = reader count
}

RW_WRITER_BIT :: 0x8000_0000

rw_read_lock :: #force_inline proc "contextless" (l: ^RWLock) {
	for {
		s := intrinsics.atomic_load(&l.state)
		if s & RW_WRITER_BIT == 0 {
			if intrinsics.atomic_compare_exchange_strong(&l.state, s, s + 1) == s {
				return
			}
		}
		intrinsics.cpu_relax()
	}
}

rw_read_unlock :: #force_inline proc "contextless" (l: ^RWLock) {
	intrinsics.atomic_sub(&l.state, 1)
}

rw_write_lock :: #force_inline proc "contextless" (l: ^RWLock) {
	for intrinsics.atomic_compare_exchange_strong(&l.state, 0, RW_WRITER_BIT) != 0 {
		intrinsics.cpu_relax()
	}
}

rw_write_unlock :: #force_inline proc "contextless" (l: ^RWLock) {
	intrinsics.atomic_store(&l.state, u32(0))
}
