package modelcheck

import "../spinlock"
import "core:strings"
import "core:testing"

RWState :: struct {
	lock:    spinlock.RWLock,
	writers: int,
	readers: int,
}

rw_reset :: proc(data: rawptr) {
	(^RWState)(data)^ = {}
}

rw_inv :: proc(data: rawptr) -> bool {
	st := (^RWState)(data)
	assert(st.writers >= 0)
	assert(st.readers >= 0)
	return st.writers == 0 || (st.writers == 1 && st.readers == 0)
}

rw_writer :: proc(data: rawptr) {
	st := (^RWState)(data)
	spinlock.rw_write_lock(&st.lock)
	st.writers += 1
	spinlock.point(.Atomic, nil)
	st.writers -= 1
	spinlock.rw_write_unlock(&st.lock)
}

rw_reader :: proc(data: rawptr) {
	st := (^RWState)(data)
	spinlock.rw_read_lock(&st.lock)
	st.readers += 1
	spinlock.point(.Atomic, nil)
	st.readers -= 1
	spinlock.rw_read_unlock(&st.lock)
}

rw_nested_reader :: proc(data: rawptr) {
	st := (^RWState)(data)
	spinlock.rw_read_lock(&st.lock)
	st.readers += 1
	spinlock.point(.Atomic, nil)
	spinlock.rw_read_lock(&st.lock)
	st.readers += 1
	spinlock.point(.Atomic, nil)
	st.readers -= 2
	spinlock.rw_read_unlock(&st.lock)
	spinlock.rw_read_unlock(&st.lock)
}

rw_check :: proc(bodies: []proc(data: rawptr)) -> Result(RaceState) {
	st: RWState
	test := Test {
		bodies = bodies,
		data   = &st,
		reset  = rw_reset,
		inv    = rw_inv,
	}
	return race_check(&test)
}

@(test)
rw_writer_writer :: proc(t: ^testing.T) {
	r := rw_check({rw_writer, rw_writer})
	testing.expectf(t, r.ok, "%s %v", r.message, r.trace)
}

@(test)
rw_writer_reader :: proc(t: ^testing.T) {
	r := rw_check({rw_writer, rw_reader})
	testing.expectf(t, r.ok, "%s %v", r.message, r.trace)
}

@(test)
rw_reader_reader :: proc(t: ^testing.T) {
	r := rw_check({rw_reader, rw_reader})
	testing.expectf(t, r.ok, "%s %v", r.message, r.trace)
}

@(test)
rw_writer_reader_reader :: proc(t: ^testing.T) {
	r := rw_check({rw_writer, rw_reader, rw_reader})
	testing.expectf(t, r.ok, "%s %v", r.message, r.trace)
}

@(test)
rw_nested_reader_writer_deadlocks :: proc(t: ^testing.T) {
	r := rw_check({rw_nested_reader, rw_writer})
	testing.expect(t, !r.ok)
	testing.expectf(t, strings.contains(r.message, "Deadlock"), "%s", r.message)
}
