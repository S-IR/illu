package modelcheck

import "../spinlock"
import "core:fmt"
import "core:sync"
import "core:thread"

Status :: enum {
	Runnable,
	Relaxed,
	Done,
}

Worker :: struct {
	sched:      ^Sched,
	body:       proc(data: rawptr),
	data:       rawptr,
	status:     Status,
	relaxAddr:  ^u32,
	relaxValue: u32,
	sema:       sync.Sema, // worker parks here
	thread:     ^thread.Thread,
}

Sched :: struct {
	workers: []Worker,
	ctrl:    sync.Sema, // controller parks here
}

@(thread_local)
self: ^Worker

hook :: proc "contextless" (kind: spinlock.PointKind, addr: ^u32) {
	w := self
	if w == nil do return

	if kind == .Relax {
		w.status = .Relaxed
		w.relaxAddr = addr
		w.relaxValue = addr^

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
	}
	delete(s.workers)
	s.workers = nil
}
MAX_WORKERS :: 8
MAX_STEPS :: 256

Test :: struct {
	bodies: []proc(data: rawptr),
	data:   rawptr,
	reset:  proc(data: rawptr), // zero State before each run
	inv:    proc(data: rawptr) -> bool, // checked by controller after every step
}
RaceError :: enum {
	None,
	Deadlock,
	StepBound,
	Invariant,
}

Schedule :: struct {
	choices: [MAX_STEPS]u8,
	len:     int,
}


execute :: proc(
	t: Test,
	prefix: []u8,
) -> (
	frontier: bit_set[0 ..< MAX_WORKERS],
	taken: Schedule,
	err: RaceError,
) {
	assert(len(t.bodies) <= MAX_WORKERS)
	assert(len(prefix) <= MAX_STEPS)
	t.reset(t.data)
	s: Sched
	controller_start(&s, t.bodies, t.data)

	outerFor: for {
		runnable: bit_set[0 ..< MAX_WORKERS]
		for &worker, i in s.workers {
			if controller_runnable(&worker) do runnable += {i}
		}
		if taken.len == len(prefix) do frontier = runnable
		if runnable == {} {
			allWorkersDone := true
			for &w in s.workers {
				if w.status != .Done {
					allWorkersDone = false
					break
				}
			}
			if allWorkersDone do break outerFor
			return frontier, taken, .Deadlock
		}
		if taken.len == MAX_STEPS do return frontier, taken, .StepBound
		i: int
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
		controller_step(&s, i)
		if !t.inv(t.data) do return frontier, taken, .Invariant
	}
	controller_finish(&s)
	return frontier, taken, .None
}
LABELS :: [MAX_WORKERS]string{"T0", "T1", "T2", "T3", "T4", "T5", "T6", "T7"}

RaceState :: struct {
	test:   ^Test,
	prefix: Schedule,
	err:    RaceError,
}

race_next :: proc(rs: RaceState) -> []Transition(RaceState) {
	assert(rs.err == .None)
	st := rs
	frontier, taken, err := execute(st.test^, st.prefix.choices[:st.prefix.len])

	if err != .None {
		child := st
		child.prefix = taken
		child.err = err
		out := make([]Transition(RaceState), 1)
		out[0] = {child, "fail"}
		return out
	}

	labels := LABELS
	out := make([dynamic]Transition(RaceState), 0, card(frontier))
	for i in frontier {
		assert(st.prefix.len < MAX_STEPS)
		child := st
		child.prefix.choices[child.prefix.len] = u8(i)
		child.prefix.len += 1
		append(&out, Transition(RaceState){child, labels[i]})
	}
	return out[:]
}

race_inv :: proc(rs: RaceState) -> (bool, string) {
	if rs.err == .None do return true, ""
	st := rs
	return false, fmt.tprintf("%v schedule %v", st.err, st.prefix.choices[:st.prefix.len])
}

race_check :: proc(t: ^Test) -> Result(RaceState) {
	assert(t != nil)
	assert(len(t.bodies) > 0)
	assert(t.reset != nil)
	assert(t.inv != nil)
	when ODIN_TEST do spinlock.schedHook = hook
	return run([]RaceState{{test = t}}, race_next, race_inv)
}
