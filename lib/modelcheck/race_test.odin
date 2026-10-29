package modelcheck

import "../spinlock"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

Shared :: struct {
	rw:    spinlock.RWLock,
	lock:  spinlock.Spinlock,
	value: int,
}

rw_writer :: proc(data: rawptr) {
	s := (^Shared)(data)
	spinlock.rw_write_lock(&s.rw, {mem.ptr_to_bytes(&s.value)})
	s.value += 1
	spinlock.rw_write_unlock(&s.rw, {mem.ptr_to_bytes(&s.value)})
}

rw_reader :: proc(data: rawptr) {
	s := (^Shared)(data)
	spinlock.rw_read_lock(&s.rw, {mem.ptr_to_bytes(&s.value)})
	assert(s.value >= 0)
	spinlock.rw_read_unlock(&s.rw, {mem.ptr_to_bytes(&s.value)})
}

rw_nested_reader :: proc(data: rawptr) {
	s := (^Shared)(data)
	spinlock.rw_read_lock(&s.rw, {mem.ptr_to_bytes(&s.value)})
	spinlock.rw_read_lock(&s.rw, {mem.ptr_to_bytes(&s.value)})
	spinlock.rw_read_unlock(&s.rw, {mem.ptr_to_bytes(&s.value)})
	spinlock.rw_read_unlock(&s.rw, {mem.ptr_to_bytes(&s.value)})
}

rw_reader_writes :: proc(data: rawptr) {
	s := (^Shared)(data)
	spinlock.rw_read_lock(&s.rw, {mem.ptr_to_bytes(&s.value)})
	s.value += 1
	spinlock.rw_read_unlock(&s.rw, {mem.ptr_to_bytes(&s.value)})
}

spin_writer :: proc(data: rawptr) {
	s := (^Shared)(data)
	spinlock.lock(&s.lock, {mem.ptr_to_bytes(&s.value)})
	s.value += 1
	spinlock.unlock(&s.lock, {mem.ptr_to_bytes(&s.value)})
}

unguarded_writer :: proc(data: rawptr) {
	s := (^Shared)(data)
	s.value += 1
}

check :: proc(bodies: []proc(data: rawptr)) -> Result(RaceState) {
	s: Shared
	return race_check({bodies = bodies, data = mem.ptr_to_bytes(&s)})
}

expect_pass :: proc(t: ^testing.T, bodies: []proc(data: rawptr)) {
	r := check(bodies)
	testing.expectf(t, r.ok, "%s %v", r.message, r.trace)
}

expect_fail :: proc(t: ^testing.T, bodies: []proc(data: rawptr), err: RaceError) {
	r := check(bodies)
	testing.expect(t, !r.ok)
	testing.expectf(t, strings.has_prefix(r.message, fmt.tprint(err)), "%s", r.message)
}

@(test)
spin_writer_writer :: proc(t: ^testing.T) {expect_pass(t, {spin_writer, spin_writer})}

@(test)
spin_writer_writer_writer :: proc(t: ^testing.T) {expect_pass(t, {spin_writer, spin_writer, spin_writer})}

@(test)
rw_writer_writer :: proc(t: ^testing.T) {expect_pass(t, {rw_writer, rw_writer})}

@(test)
rw_writer_reader :: proc(t: ^testing.T) {expect_pass(t, {rw_writer, rw_reader})}

@(test)
rw_reader_reader :: proc(t: ^testing.T) {expect_pass(t, {rw_reader, rw_reader})}

@(test)
rw_writer_reader_reader :: proc(t: ^testing.T) {expect_pass(t, {rw_writer, rw_reader, rw_reader})}

@(test)
rw_nested_reader_writer_deadlocks :: proc(t: ^testing.T) {expect_fail(t, {rw_nested_reader, rw_writer}, .Deadlock)}

@(test)
rw_reader_write_races :: proc(t: ^testing.T) {expect_fail(t, {rw_reader_writes, rw_reader}, .Race)}

@(test)
unguarded_write_races :: proc(t: ^testing.T) {expect_fail(t, {unguarded_writer, spin_writer}, .Race)}
