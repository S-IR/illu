#+test
package kernel

import "../lib/modelcheck"
import "core:fmt"
import "core:testing"

PD_TEST_NUM :: 2
PD_MAX_STEPS :: 6 // bounds the search depth so it terminates; the ABA bug this catches shows up at depth 3

pdTestPool: [PD_TEST_NUM]ProtectionDomain

PdState :: struct {
	prots:         [PD_TEST_NUM]^ProtectionDomain,
	protsLen:      int,
	slotGen:       [PD_TEST_NUM]u32,
	freeSlots:     [PD_TEST_NUM]int,
	freeLen:       int,
	domainSlotIdx: [PD_TEST_NUM]int,
	registered:    [PD_TEST_NUM]bool,
	handles:       [PD_TEST_NUM]u64,
	steps:         int,
}

pd_restore :: proc(s: PdState) {
	prots := s.prots
	slotGen := s.slotGen
	freeSlots := s.freeSlots
	resize(&currentProtDomains.prots, s.protsLen)
	copy(currentProtDomains.prots[:], prots[:s.protsLen])
	resize(&currentProtDomains.generations, s.protsLen)
	copy(currentProtDomains.generations[:], slotGen[:s.protsLen])
	resize(&currentProtDomains.freeSlots, s.freeLen)
	copy(currentProtDomains.freeSlots[:], freeSlots[:s.freeLen])
	for i in 0 ..< PD_TEST_NUM {
		pdTestPool[i].slotIdx = s.domainSlotIdx[i]
		if s.registered[i] do pdTestPool[i].generation = currentProtDomains.generations[pdTestPool[i].slotIdx]
	}
}

pd_snapshot :: proc(registered: [PD_TEST_NUM]bool, handles: [PD_TEST_NUM]u64, steps: int) -> PdState {
	ns: PdState
	ns.protsLen = len(currentProtDomains.prots)
	copy(ns.prots[:ns.protsLen], currentProtDomains.prots[:])
	for i in 0 ..< ns.protsLen do ns.slotGen[i] = currentProtDomains.generations[i]
	ns.freeLen = len(currentProtDomains.freeSlots)
	copy(ns.freeSlots[:ns.freeLen], currentProtDomains.freeSlots[:])
	for i in 0 ..< PD_TEST_NUM do ns.domainSlotIdx[i] = pdTestPool[i].slotIdx
	ns.registered = registered
	ns.handles = handles
	ns.steps = steps
	return ns
}

pd_init :: proc() -> PdState {
	currentProtDomains.prots = nil
	currentProtDomains.generations = nil
	currentProtDomains.freeSlots = nil
	for i in 0 ..< PD_TEST_NUM do pdTestPool[i] = {}
	registered: [PD_TEST_NUM]bool
	handles: [PD_TEST_NUM]u64
	return pd_snapshot(registered, handles, 0)
}

pd_next :: proc(s: PdState) -> []modelcheck.Transition(PdState) {
	out: [dynamic]modelcheck.Transition(PdState)
	if s.steps >= PD_MAX_STEPS do return out[:]

	for i in 0 ..< PD_TEST_NUM {
		if s.registered[i] do continue
		pd_restore(s)
		protdomain_register(&pdTestPool[i])
		currentProtDomains.generations[pdTestPool[i].slotIdx] = pdTestPool[i].generation
		newHandles := s.handles
		newHandles[i] = protdomain_handle_encode(&pdTestPool[i])
		newRegistered := s.registered
		newRegistered[i] = true
		append(&out, modelcheck.Transition(PdState){pd_snapshot(newRegistered, newHandles, s.steps + 1), fmt.tprintf("register(%d)", i)})
	}

	for i in 0 ..< PD_TEST_NUM {
		if !s.registered[i] do continue
		pd_restore(s)
		protdomain_unregister(&pdTestPool[i])
		newRegistered := s.registered
		newRegistered[i] = false
		append(&out, modelcheck.Transition(PdState){pd_snapshot(newRegistered, s.handles, s.steps + 1), fmt.tprintf("unregister(%d)", i)})
	}

	return out[:]
}

pd_inv :: proc(s: PdState) -> (ok: bool, msg: string) {
	pd_restore(s)

	for i in 0 ..< s.freeLen {
		idx := s.freeSlots[i]
		if idx < 0 || idx >= s.protsLen {
			return false, fmt.tprintf("freeSlots contains out-of-range index %d", idx)
		}
		if s.prots[idx] != nil {
			return false, fmt.tprintf("slot %d is listed both free and occupied", idx)
		}
	}

	for i in 0 ..< PD_TEST_NUM {
		resolved := protdomain_handle_resolve(s.handles[i])
		if s.registered[i] {
			if resolved != &pdTestPool[i] {
				return false, fmt.tprintf("domain %d's own handle does not resolve back to it", i)
			}
		} else if resolved != nil {
			return false, fmt.tprintf("domain %d's stale handle still resolves after unregister", i)
		}
	}

	return true, ""
}

@(test)
TestProtDomainRegistryModel :: proc(t: ^testing.T) {
	init := pd_init()
	r := modelcheck.run([]PdState{init}, pd_next, pd_inv)
	if !r.ok do fmt.println(r.trace)
	testing.expect(t, r.ok, r.message)
}
