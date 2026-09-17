#+test
package kernel

import "../lib/modelcheck"
import "core:fmt"
import "core:testing"

EXEC_TEST_NUM :: 3

execTestPool: [EXEC_TEST_NUM]Execution
execTestDomain: ProtectionDomain

ExecQState :: struct {
	nextIdx: [EXEC_TEST_NUM]int,
	headIdx: int,
	tailIdx: int,
	queued:  [EXEC_TEST_NUM]bool,
}

exec_idx_of :: proc(e: ^Execution) -> int {
	for i in 0 ..< EXEC_TEST_NUM do if &execTestPool[i] == e do return i
	return -1
}

exec_q_restore :: proc(s: ExecQState, cpu: ^CpuState) {
	for i in 0 ..< EXEC_TEST_NUM {
		execTestPool[i].next = s.nextIdx[i] == -1 ? nil : &execTestPool[s.nextIdx[i]]
	}
	cpu.rrHead = s.headIdx == -1 ? nil : &execTestPool[s.headIdx]
	cpu.rrTail = s.tailIdx == -1 ? nil : &execTestPool[s.tailIdx]
}

exec_q_snapshot :: proc(cpu: ^CpuState) -> ExecQState {
	ns: ExecQState
	for i in 0 ..< EXEC_TEST_NUM do ns.nextIdx[i] = -1
	n := cpu.rrHead
	for n != nil {
		i := exec_idx_of(n)
		ns.queued[i] = true
		if n.next != nil do ns.nextIdx[i] = exec_idx_of(n.next)
		n = n.next
	}
	ns.headIdx = cpu.rrHead == nil ? -1 : exec_idx_of(cpu.rrHead)
	ns.tailIdx = cpu.rrTail == nil ? -1 : exec_idx_of(cpu.rrTail)
	return ns
}

exec_q_next :: proc(s: ExecQState) -> []modelcheck.Transition(ExecQState) {
	cpu: CpuState
	out: [dynamic]modelcheck.Transition(ExecQState)

	for i in 0 ..< EXEC_TEST_NUM {
		if s.queued[i] do continue
		exec_q_restore(s, &cpu)
		execution_enqueue(&execTestPool[i], &cpu)
		append(&out, modelcheck.Transition(ExecQState){exec_q_snapshot(&cpu), fmt.tprintf("enqueue(%d)", i)})

		exec_q_restore(s, &cpu)
		execution_enqueue_front(&execTestPool[i], &cpu)
		append(&out, modelcheck.Transition(ExecQState){exec_q_snapshot(&cpu), fmt.tprintf("enqueue_front(%d)", i)})
	}

	if s.headIdx != -1 {
		exec_q_restore(s, &cpu)
		popped := execution_dequeue(&cpu)
		append(&out, modelcheck.Transition(ExecQState){exec_q_snapshot(&cpu), fmt.tprintf("dequeue -> %d", exec_idx_of(popped))})
	}

	return out[:]
}

exec_q_inv :: proc(s: ExecQState) -> (bool, string) {
	if (s.headIdx == -1) != (s.tailIdx == -1) {
		return false, "head/tail disagree about emptiness"
	}
	seen: [EXEC_TEST_NUM]bool
	i := s.headIdx
	steps := 0
	for i != -1 {
		if seen[i] do return false, fmt.tprintf("cycle in run queue at node %d", i)
		seen[i] = true
		steps += 1
		if steps > EXEC_TEST_NUM do return false, "queue longer than node pool"
		if s.nextIdx[i] == -1 && i != s.tailIdx {
			return false, fmt.tprintf("node %d has no successor but isn't tail", i)
		}
		i = s.nextIdx[i]
	}
	for i in 0 ..< EXEC_TEST_NUM {
		if s.queued[i] != seen[i] {
			return false, fmt.tprintf("node %d queued-flag disagrees with list reachability", i)
		}
	}
	return true, ""
}

@(test)
TestExecutionQueueModel :: proc(t: ^testing.T) {
	execTestDomain.executionCount = 1
	for i in 0 ..< EXEC_TEST_NUM {
		execTestPool[i] = Execution{schedulerState = .Runnable, domain = &execTestDomain}
	}
	init: ExecQState
	init.headIdx = -1
	init.tailIdx = -1
	for i in 0 ..< EXEC_TEST_NUM do init.nextIdx[i] = -1

	r := modelcheck.run([]ExecQState{init}, exec_q_next, exec_q_inv)
	if !r.ok do fmt.println(r.trace)
	testing.expect(t, r.ok, r.message)
}
