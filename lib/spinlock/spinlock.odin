package spinlock
import "base:intrinsics"

Spinlock :: struct {
	locked: u32,
}

lock :: #force_inline proc "contextless" (l: ^Spinlock) {
	for intrinsics.atomic_compare_exchange_strong(&l.locked, 0, 1) != 0 {
		intrinsics.cpu_relax()
	}
}

unlock :: #force_inline proc "contextless" (l: ^Spinlock) {
	intrinsics.atomic_store(&l.locked, u32(0))
}
