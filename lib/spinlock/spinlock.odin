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
