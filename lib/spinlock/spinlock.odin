package spinlock
import "base:intrinsics"

Spinlock :: struct {
	locked: u32,
}

lock :: #force_inline proc "contextless" (l: ^Spinlock) {
	for {
		if intrinsics.atomic_exchange_explicit(&l.locked, 1, .Acquire) == 0 do return
		for intrinsics.atomic_load_explicit(&l.locked, .Relaxed) != 0 do intrinsics.cpu_relax()
	}
}

unlock :: #force_inline proc "contextless" (l: ^Spinlock) {
	assert_contextless(intrinsics.atomic_load_explicit(&l.locked, .Relaxed) == 1)
	intrinsics.atomic_store_explicit(&l.locked, 0, .Release)
}

RWLock :: struct {
	state: u32,
}

RW_WRITER_BIT :: u32(0x8000_0000)
RW_READERS_MASK :: RW_WRITER_BIT - 1

rw_read_lock :: #force_inline proc "contextless" (l: ^RWLock) {
	for {
		s := intrinsics.atomic_load_explicit(&l.state, .Relaxed)
		if s & RW_WRITER_BIT != 0 {
			intrinsics.cpu_relax()
			continue
		}
		assert_contextless(s & RW_READERS_MASK != RW_READERS_MASK)
		if _, ok := intrinsics.atomic_compare_exchange_weak_explicit(&l.state, s, s + 1, .Acquire, .Relaxed); ok do return
	}
}

rw_read_unlock :: #force_inline proc "contextless" (l: ^RWLock) {
	previous := intrinsics.atomic_sub_explicit(&l.state, 1, .Release)
	assert_contextless(previous & RW_READERS_MASK != 0)
}

rw_write_lock :: #force_inline proc "contextless" (l: ^RWLock) {
	for {
		s := intrinsics.atomic_load_explicit(&l.state, .Relaxed)
		if s & RW_WRITER_BIT != 0 {
			intrinsics.cpu_relax()
			continue
		}
		if _, ok := intrinsics.atomic_compare_exchange_weak_explicit(&l.state, s, s | RW_WRITER_BIT, .Acquire, .Relaxed); ok do break
	}
	for intrinsics.atomic_load_explicit(&l.state, .Acquire) != RW_WRITER_BIT do intrinsics.cpu_relax()
}

rw_write_unlock :: #force_inline proc "contextless" (l: ^RWLock) {
	assert_contextless(intrinsics.atomic_load_explicit(&l.state, .Relaxed) == RW_WRITER_BIT)
	intrinsics.atomic_store_explicit(&l.state, 0, .Release)
}
