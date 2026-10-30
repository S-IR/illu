package spinlock
import "base:intrinsics"

PointKind :: enum {
	Atomic,
	Result,
	Relax,
	AcquireRead,
	AcquireWrite,
	ReleaseRead,
	ReleaseWrite,
}

when ODIN_TEST {
	schedHook: proc "contextless" (kind: PointKind, addr: ^u32, value: u32, guards: [][]u8) = nil
}

point :: #force_inline proc "contextless" (
	kind: PointKind,
	addr: ^u32,
	value: u32 = 0,
	guards: [][]u8 = nil,
) {
	when ODIN_TEST {
		if schedHook != nil do schedHook(kind, addr, value, guards)
	}
}

Spinlock :: struct {
	locked: u32,
}

lock :: #force_inline proc "contextless" (l: ^Spinlock, guards: [][]u8) {
	for {
		point(.Atomic, &l.locked)
		old := intrinsics.atomic_exchange_explicit(&l.locked, 1, .Acquire)
		point(.Result, &l.locked, old)
		if old == 0 do break
		point(.Atomic, &l.locked)
		for {
			v := intrinsics.atomic_load_explicit(&l.locked, .Relaxed)
			point(.Result, &l.locked, v)
			if v == 0 do break
			point(.Relax, &l.locked, v)
			intrinsics.cpu_relax()
		}
	}
	point(.AcquireWrite, &l.locked, guards = guards)
}

unlock :: #force_inline proc "contextless" (l: ^Spinlock, guards: [][]u8) {
	point(.ReleaseWrite, &l.locked, guards = guards)
	v := intrinsics.atomic_load_explicit(&l.locked, .Relaxed)
	point(.Result, &l.locked, v)
	assert_contextless(v == 1)
	point(.Atomic, &l.locked)
	intrinsics.atomic_store_explicit(&l.locked, 0, .Release)
}

RWLock :: struct {
	state: u32,
}

RW_WRITER_BIT :: u32(0x8000_0000)
RW_READERS_MASK :: RW_WRITER_BIT - 1

rw_read_lock :: #force_inline proc "contextless" (l: ^RWLock, guards: [][]byte) {
	point(.Atomic, &l.state)
	for {
		s := intrinsics.atomic_load_explicit(&l.state, .Relaxed)
		point(.Result, &l.state, s)
		if s & RW_WRITER_BIT != 0 {
			point(.Relax, &l.state, s)
			intrinsics.cpu_relax()
			continue
		}
		assert_contextless(s & RW_READERS_MASK != RW_READERS_MASK)
		point(.Atomic, &l.state)
		old, ok := intrinsics.atomic_compare_exchange_weak_explicit(
			&l.state,
			s,
			s + 1,
			.Acquire,
			.Relaxed,
		)
		point(.Result, &l.state, old)
		if ok do break
		point(.Atomic, &l.state)
	}
	point(.AcquireRead, &l.state, guards = guards)
}

rw_read_unlock :: #force_inline proc "contextless" (l: ^RWLock, guards: [][]u8) {
	point(.ReleaseRead, &l.state, guards = guards)
	previous := intrinsics.atomic_sub_explicit(&l.state, 1, .Release)
	point(.Result, &l.state, previous)
	assert_contextless(previous & RW_READERS_MASK != 0)
}

rw_write_lock :: #force_inline proc "contextless" (l: ^RWLock, guards: [][]u8) {
	point(.Atomic, &l.state)
	for {
		s := intrinsics.atomic_load_explicit(&l.state, .Relaxed)
		point(.Result, &l.state, s)
		if s & RW_WRITER_BIT != 0 {
			point(.Relax, &l.state, s)
			intrinsics.cpu_relax()
			continue
		}
		point(.Atomic, &l.state)
		old, ok := intrinsics.atomic_compare_exchange_weak_explicit(
			&l.state,
			s,
			s | RW_WRITER_BIT,
			.Acquire,
			.Relaxed,
		)
		point(.Result, &l.state, old)
		if ok do break
		point(.Atomic, &l.state)
	}
	point(.Atomic, &l.state)
	for {
		v := intrinsics.atomic_load_explicit(&l.state, .Acquire)
		point(.Result, &l.state, v)
		if v == RW_WRITER_BIT do break
		point(.Relax, &l.state, v)
		intrinsics.cpu_relax()
	}
	point(.AcquireWrite, &l.state, guards = guards)
}

rw_write_unlock :: #force_inline proc "contextless" (l: ^RWLock, guards: [][]u8) {
	point(.ReleaseWrite, &l.state, guards = guards)
	v := intrinsics.atomic_load_explicit(&l.state, .Relaxed)
	point(.Result, &l.state, v)
	assert_contextless(v == RW_WRITER_BIT)
	point(.Atomic, &l.state)
	intrinsics.atomic_store_explicit(&l.state, 0, .Release)
}
