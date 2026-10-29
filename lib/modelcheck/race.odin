package modelcheck

import "../spinlock"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

MAX_WORKERS :: 8
MAX_STEPS :: 256
LOCK_WORD_SIZE :: size_of(u32)

Status :: enum {
	Runnable,
	Relaxed,
	Done,
}

Held :: struct {
	bytes: []u8,
	write: bool,
}

Worker :: struct {
	sched:      ^Sched,
	body:       proc(data: rawptr),
	data:       rawptr,
	status:     Status,
	kind:       spinlock.PointKind,
	addr:       ^u32,
	guards:     [][]u8,
	relaxAddr:  ^u32,
	relaxValue: u32,
	results:    [2]u32,
	nResults:   int,
	history:    u32,
	held:       [dynamic]Held,
	sema:       sync.Sema,
	thread:     ^thread.Thread,
}

Sched :: struct {
	workers: []Worker,
	ctrl:    sync.Sema,
}

@(thread_local)
self: ^Worker

hook :: proc "contextless" (kind: spinlock.PointKind, addr: ^u32, value: u32, guards: [][]u8) {
	w := self
	if w == nil do return

	if kind == .Result {
		assert_contextless(w.nResults < len(w.results))
		w.results[w.nResults] = value
		w.nResults += 1
		return
	}
	w.kind = kind
	w.addr = addr
	w.guards = guards
	if kind == .Relax {
		w.status = .Relaxed
		w.relaxAddr = addr
		w.relaxValue = value
	}
	sync.sema_post(&w.sched.ctrl)
	sync.sema_wait(&w.sema)
}

worker_entry :: proc(w: ^Worker) {
	self = w
	sync.sema_wait(&w.sema)
	w.body(w.data)
	w.status = .Done
	sync.sema_post(&w.sched.ctrl)
}

controller_runnable :: proc(w: ^Worker) -> bool {
	switch w.status {
	case .Done:
		return false
	case .Runnable:
		return true
	case .Relaxed:
		assert(w.relaxAddr != nil)
		return w.relaxAddr^ != w.relaxValue
	}
	unreachable()
}

controller_step :: proc(s: ^Sched, i: int) {
	w := &s.workers[i]
	assert(controller_runnable(w))
	w.status = .Runnable
	sync.sema_post(&w.sema)
	sync.sema_wait(&s.ctrl)
}

controller_start :: proc(s: ^Sched, bodies: []proc(data: rawptr), data: rawptr) {
	assert(len(bodies) > 0)
	assert(len(bodies) <= MAX_WORKERS)
	assert(data != nil)
	assert(s.workers == nil)
	s.workers = make([]Worker, len(bodies))
	for &worker, i in s.workers {
		worker.sched = s
		worker.data = data
		worker.body = bodies[i]
		worker.thread = thread.create_and_start_with_poly_data(&worker, worker_entry)
		assert(worker.thread != nil)
	}
}

controller_finish :: proc(s: ^Sched) {
	assert(s.workers != nil)
	for &worker in s.workers {
		assert(worker.status == .Done)
		thread.join(worker.thread)
		thread.destroy(worker.thread)
		delete(worker.held)
	}
	delete(s.workers)
	s.workers = nil
}

Test :: struct {
	bodies: []proc(data: rawptr),
	data:   []u8,
}

RaceError :: enum {
	None,
	Race,
	Exclusion,
	Unheld,
	Deadlock,
	StepBound,
}

Schedule :: struct {
	choices: [MAX_STEPS]u8,
	len:     int,
}

Key :: struct {
	mem:       u32,
	histories: [MAX_WORKERS]u32,
}

Known :: struct {
	prefix:   Schedule,
	frontier: bit_set[0 ..< MAX_WORKERS],
}

Checker :: struct {
	test:    Test,
	initial: []u8,
	watched: [dynamic][]u8,
	prev:    [dynamic]u8,
	mems:    map[string]u32,
	trie:    map[[3]u32]u32,
	known:   map[Key]Known,
	failed:  Schedule,
}

checker_destroy :: proc(c: ^Checker) {
	for k in c.mems do delete(k)
	delete(c.mems)
	delete(c.trie)
	delete(c.known)
	delete(c.watched)
	delete(c.prev)
	delete(c.initial)
}

intern :: proc(c: ^Checker, bytes: []u8) -> u32 {
	if id, ok := c.mems[string(bytes)]; ok do return id
	id := u32(len(c.mems)) + 1
	c.mems[strings.clone(string(bytes))] = id
	return id
}

DONE_TAG :: u32(len(spinlock.PointKind))

history_append :: proc(c: ^Checker, node: u32, tag: u32, value: u32) -> u32 {
	k := [3]u32{node, tag, value}
	if id, ok := c.trie[k]; ok do return id
	id := u32(len(c.trie)) + 1
	c.trie[k] = id
	return id
}

contains :: proc(region: []u8, p: uintptr, size: uintptr) -> bool {
	start := uintptr(raw_data(region))
	return p >= start && p + size <= start + uintptr(len(region))
}

overlaps :: proc(a, b: []u8) -> bool {
	aStart, bStart := uintptr(raw_data(a)), uintptr(raw_data(b))
	return aStart < bStart + uintptr(len(b)) && bStart < aStart + uintptr(len(a))
}

write_allowed :: proc(w: ^Worker, exempt: ^u32, p: uintptr) -> bool {
	if exempt != nil && p >= uintptr(exempt) && p < uintptr(exempt) + LOCK_WORD_SIZE do return true
	for h in w.held {
		if h.write && contains(h.bytes, p, 1) do return true
	}
	return false
}

step_exempt :: proc(w: ^Worker) -> ^u32 {
	#partial switch w.kind {
	case .Atomic, .Relax, .ReleaseRead, .ReleaseWrite:
		return w.addr
	}
	return nil
}

watch :: proc(c: ^Checker, s: ^Sched) {
	clear(&c.watched)
	clear(&c.prev)
	append(&c.watched, c.test.data)
	for w in s.workers {
		for h in w.held do append(&c.watched, h.bytes)
	}
	for r in c.watched do append(&c.prev, ..r)
}

check_writes :: proc(c: ^Checker, w: ^Worker, exempt: ^u32) -> RaceError {
	prev := c.prev[:]
	for r in c.watched {
		for j in 0 ..< len(r) {
			if r[j] != prev[j] && !write_allowed(w, exempt, uintptr(&r[j])) do return .Race
		}
		prev = prev[len(r):]
	}
	assert(len(prev) == 0)
	return .None
}

acquire :: proc(c: ^Checker, s: ^Sched, w: ^Worker, write: bool) -> RaceError {
	view: [dynamic]u8
	defer delete(view)
	for g in w.guards {
		if len(g) == 0 do continue
		for &other in s.workers {
			if &other == w do continue
			for h in other.held {
				if overlaps(h.bytes, g) && (write || h.write) do return .Exclusion
			}
		}
		append(&view, ..g)
		append(&w.held, Held{g, write})
	}
	w.history = history_append(c, w.history, u32(w.kind), intern(c, view[:]))
	return .None
}

release :: proc(w: ^Worker, write: bool) -> RaceError {
	outer: for g in w.guards {
		if len(g) == 0 do continue
		for h, i in w.held {
			if raw_data(h.bytes) == raw_data(g) && len(h.bytes) == len(g) && h.write == write {
				unordered_remove(&w.held, i)
				continue outer
			}
		}
		return .Unheld
	}
	return .None
}

after_step :: proc(c: ^Checker, s: ^Sched, w: ^Worker, exempt: ^u32) -> RaceError {
	check_writes(c, w, exempt) or_return
	for r in w.results[:w.nResults] {
		w.history = history_append(c, w.history, u32(spinlock.PointKind.Result), r)
	}
	w.nResults = 0
	if w.status == .Done {
		w.history = history_append(c, w.history, DONE_TAG, 0)
		return .None
	}
	w.history = history_append(c, w.history, u32(w.kind), 0)
	#partial switch w.kind {
	case .AcquireRead:
		return acquire(c, s, w, false)
	case .AcquireWrite:
		return acquire(c, s, w, true)
	case .ReleaseRead:
		return release(w, false)
	case .ReleaseWrite:
		return release(w, true)
	}
	return .None
}

state_key :: proc(c: ^Checker, s: ^Sched) -> (key: Key) {
	watch(c, s)
	key.mem = intern(c, c.prev[:])
	for w, i in s.workers do key.histories[i] = w.history
	return
}

execute :: proc(
	c: ^Checker,
	prefix: []u8,
) -> (
	key: Key,
	frontier: bit_set[0 ..< MAX_WORKERS],
	taken: Schedule,
	err: RaceError,
) {
	assert(len(prefix) <= MAX_STEPS)
	copy(c.test.data, c.initial)
	s: Sched
	controller_start(&s, c.test.bodies, raw_data(c.test.data))

	for {
		runnable: bit_set[0 ..< MAX_WORKERS]
		for &w, i in s.workers {
			if controller_runnable(&w) do runnable += {i}
		}
		if taken.len == len(prefix) {
			key = state_key(c, &s)
			frontier = runnable
		}
		if runnable == {} {
			for w in s.workers {
				if w.status != .Done do return key, frontier, taken, .Deadlock
			}
			break
		}
		if taken.len == MAX_STEPS do return key, frontier, taken, .StepBound
		i := -1
		if taken.len < len(prefix) {
			i = int(prefix[taken.len])
		} else {
			for j in runnable {
				i = j
				break
			}
		}
		assert(i in runnable)
		taken.choices[taken.len] = u8(i)
		taken.len += 1
		w := &s.workers[i]
		exempt := step_exempt(w)
		watch(c, &s)
		controller_step(&s, i)
		if e := after_step(c, &s, w, exempt); e != .None do return key, frontier, taken, e
	}
	controller_finish(&s)
	return key, frontier, taken, .None
}

LABELS :: [MAX_WORKERS]string{"T0", "T1", "T2", "T3", "T4", "T5", "T6", "T7"}

RaceState :: struct {
	checker: ^Checker,
	key:     Key,
	err:     RaceError,
}

race_next :: proc(rs: RaceState) -> []Transition(RaceState) {
	assert(rs.err == .None)
	c := rs.checker
	known, ok := c.known[rs.key]
	assert(ok)
	labels := LABELS
	out := make([dynamic]Transition(RaceState), 0, card(known.frontier))
	for i in known.frontier {
		assert(known.prefix.len < MAX_STEPS)
		prefix := known.prefix
		prefix.choices[prefix.len] = u8(i)
		prefix.len += 1
		key, frontier, taken, err := execute(c, prefix.choices[:prefix.len])
		if err != .None {
			c.failed = taken
			append(&out, Transition(RaceState){{c, {}, err}, labels[i]})
			return out[:]
		}
		if key not_in c.known do c.known[key] = {prefix, frontier}
		append(&out, Transition(RaceState){{c, key, .None}, labels[i]})
	}
	return out[:]
}

race_inv :: proc(rs: RaceState) -> (bool, string) {
	if rs.err == .None do return true, ""
	failed := &rs.checker.failed
	return false, fmt.tprintf("%v schedule %v", rs.err, failed.choices[:failed.len])
}

race_check :: proc(t: Test) -> Result(RaceState) {
	assert(len(t.bodies) > 0)
	assert(len(t.bodies) <= MAX_WORKERS)
	assert(len(t.data) > 0)
	c := Checker {
		test    = t,
		initial = slice.clone(t.data),
	}
	defer checker_destroy(&c)
	when ODIN_TEST do spinlock.schedHook = hook

	key, frontier, taken, err := execute(&c, nil)
	if err != .None {
		c.failed = taken
		return run([]RaceState{{&c, {}, err}}, race_next, race_inv)
	}
	c.known[key] = {{}, frontier}
	return run([]RaceState{{&c, key, .None}}, race_next, race_inv)
}
