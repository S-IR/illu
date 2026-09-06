package modelcheck

// Models the concurrency contract of the global protection-domain pool
// (kernel/mempool.odin: domainPool) plus the per-domain execution pool
// (kernel/execution.odin), abstracted down to plain comparable state so it
// can be BFS'd by this checker. See kernel/protdomain.odin and
// kernel/execution.odin for the real code this mirrors.
//
// The mechanism under test is execution_release:
//
//   execution_release :: proc(ref: ExecutionRef) {
//       lastOne := false
//       {
//           spinlock.lock(&domainPool.lock)
//           defer spinlock.unlock(&domainPool.lock)
//           ...
//           execution_pool_free(domain, ref.exec)                 // step A
//           lastOne = domain_execution_count(domain) == 0         // step A
//       }
//       if lastOne do domain_pool_free(ref.domain)                // step B
//   }
//
// Step A (decrement + latch "was that the last one") and step B (actually
// tear the domain down) are two SEPARATE lock acquisitions, not one. Between
// them, nothing stops another CPU holding a live handle to the SAME domain
// from calling execution_create and adding a fresh execution to it -- the
// domain hasn't been freed yet, domain_pool_resolve still succeeds. Step B
// then runs anyway, because lastOne already latched true, and tears the
// domain down (domain_pool_free asserts domain_execution_count(domain) == 0
// first, but an assert that fires in a debug build still corrupts state in
// a release build with asserts stripped -- the invariant below checks the
// actual safety property regardless of whether the assert would have fired).
//
// One domain slot is modeled (idx is fixed; only generation/allocated/
// execCount/freeCount vary), with NUM_WORKERS abstract callers: two start
// out already holding an execution in that domain and race to release it,
// one starts idle and races to add a new execution to the same domain.

import "core:fmt"
import "core:testing"

NUM_WORKERS :: 3

WorkerPC :: enum {
	Idle, // may call execution_create against the domain
	Holding, // holds one execution slot; may run release step A
	ReleasedStepA, // step A done, lastOne latched; may run step B
	Done,
}

DomainRaceState :: struct {
	allocated:  bool,
	generation: u8, // bounded (wraps) purely to keep the state space finite
	execCount:  u8,
	freeCount:  u8, // times this slot has been pushed onto domainPool.freeSlots
	pc:         [NUM_WORKERS]WorkerPC,
	lastOne:    [NUM_WORKERS]bool,
}

domain_race_next :: proc(s: DomainRaceState) -> []Transition(DomainRaceState) {
	out: [dynamic]Transition(DomainRaceState)
	for p in 0 ..< NUM_WORKERS {
		switch s.pc[p] {
		case .Idle:
			// execution_pool_alloc: only requires the domain to still be
			// live -- doesn't care whether anyone else is mid-release.
			if s.allocated {
				ns := s
				ns.execCount += 1
				ns.pc[p] = .Holding
				append(&out, Transition(DomainRaceState){ns, fmt.tprintf("execution_create(w%d)", p)})
			}
		case .Holding:
			// execution_release step A: locked decrement + latch lastOne.
			ns := s
			ns.execCount -= 1
			ns.lastOne[p] = ns.execCount == 0
			ns.pc[p] = .ReleasedStepA
			append(&out, Transition(DomainRaceState){ns, fmt.tprintf("release_stepA(w%d)", p)})
		case .ReleasedStepA:
			// execution_release step B: re-locks and, only if THIS worker
			// latched lastOne, tears the domain down -- unconditionally on
			// whatever execCount reads *now*, not what it read at step A.
			ns := s
			ns.pc[p] = .Done
			label: string
			if s.lastOne[p] {
				ns.allocated = false
				ns.freeCount += 1
				ns.generation = (s.generation + 1) % 4
				label = fmt.tprintf("release_stepB_destroy(w%d)", p)
			} else {
				label = fmt.tprintf("release_stepB_noop(w%d)", p)
			}
			append(&out, Transition(DomainRaceState){ns, label})
		case .Done:
		// terminal
		}
	}
	return out[:]
}

domain_race_inv :: proc(s: DomainRaceState) -> (ok: bool, msg: string) {
	if !s.allocated && s.execCount != 0 {
		return false,
			"domain was torn down (protection_domain_destroy, pml4 + executions freed) while execCount != 0 -- a live execution's backing memory just vanished out from under it (use-after-free)"
	}
	if s.freeCount > 1 {
		return false, "domain's slot was pushed onto domainPool.freeSlots more than once -- double free of the free list, next domain_pool_alloc can hand the same slot to two callers at once"
	}
	if s.allocated && s.generation == 0 {
		return false, "an allocated domain has generation == 0, the sentinel reserved for \"never valid\""
	}
	return true, ""
}

@(test)
TestDomainPoolExecutionReleaseRace :: proc(t: ^testing.T) {
	init := DomainRaceState {
		allocated  = true,
		generation = 1,
		execCount  = 2,
		pc         = {.Holding, .Holding, .Idle}, // w0,w1 hold the two live executions; w2 races to add one
	}
	r := run([]DomainRaceState{init}, domain_race_next, domain_race_inv)
	if !r.ok {
		fmt.println(r.trace)
	}
	testing.expect(
		t,
		r.ok,
		fmt.tprintf(
			"execution_release has a real TOCTOU race: releasing the last execution in a domain can tear the domain down while another CPU has just added a new execution to it. %s",
			r.message,
		),
	)
}
