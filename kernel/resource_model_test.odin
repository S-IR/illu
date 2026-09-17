#+test
package kernel

import "../lib/modelcheck"
import "core:fmt"
import "core:testing"

RES_NUM_CANDIDATES :: 3

resCandidates := [RES_NUM_CANDIDATES]MemoryResource {
	{overlay = {phys = 0x1000, size = 0x1000}},
	{overlay = {phys = 0x2000, size = 0x1000}},
	{overlay = {phys = 0x1800, size = 0x1000}},
}

resList: [dynamic]MemoryResource

ResState :: struct {
	len:  int,
	phys: [RES_NUM_CANDIDATES]u64,
	size: [RES_NUM_CANDIDATES]u64,
}

res_restore :: proc(s: ResState) {
	clear(&resList)
	for i in 0 ..< s.len {
		append(&resList, MemoryResource{overlay = {phys = s.phys[i], size = s.size[i]}})
	}
}

res_snapshot :: proc() -> ResState {
	ns: ResState
	ns.len = len(resList)
	for i in 0 ..< ns.len {
		ns.phys[i] = resList[i].overlay.phys
		ns.size[i] = resList[i].overlay.size
	}
	return ns
}

res_next :: proc(s: ResState) -> []modelcheck.Transition(ResState) {
	out: [dynamic]modelcheck.Transition(ResState)

	for c in 0 ..< RES_NUM_CANDIDATES {
		res_restore(s)
		resource_insert(&resList, resCandidates[c])
		append(&out, modelcheck.Transition(ResState){res_snapshot(), fmt.tprintf("insert(%d)", c)})

		res_restore(s)
		resource_remove(&resList, resCandidates[c].overlay.phys)
		append(&out, modelcheck.Transition(ResState){res_snapshot(), fmt.tprintf("remove(%d)", c)})
	}

	return out[:]
}

res_inv :: proc(s: ResState) -> (bool, string) {
	for i in 1 ..< s.len {
		if s.phys[i] <= s.phys[i-1] {
			return false, fmt.tprintf("resource list not sorted at index %d", i)
		}
		if s.phys[i] < s.phys[i-1] + s.size[i-1] {
			return false, fmt.tprintf("resources %d and %d overlap", i - 1, i)
		}
	}

	view: [RES_NUM_CANDIDATES]MemoryResource
	for i in 0 ..< s.len do view[i] = MemoryResource{overlay = {phys = s.phys[i], size = s.size[i]}}
	slice := view[:s.len]

	for c in 0 ..< RES_NUM_CANDIDATES {
		p, sz := resCandidates[c].overlay.phys, resCandidates[c].overlay.size
		for probe in ([4]u64{p - 1, p, p + sz - 1, p + sz}) {
			bfExact := false
			for e in slice do if e.overlay.phys == probe do bfExact = true
			_, realExact := resource_find_exact(slice, probe)
			if realExact != bfExact {
				return false, fmt.tprintf("resource_find_exact(%x) disagrees with linear scan", probe)
			}

			bfCont := false
			for e in slice do if probe >= e.overlay.phys && probe < e.overlay.phys + e.overlay.size do bfCont = true
			_, realCont := resource_find_containing(slice, probe)
			if realCont != bfCont {
				return false, fmt.tprintf("resource_find_containing(%x) disagrees with linear scan", probe)
			}
		}
	}

	return true, ""
}

@(test)
TestResourceListModel :: proc(t: ^testing.T) {
	init: ResState
	r := modelcheck.run([]ResState{init}, res_next, res_inv)
	if !r.ok do fmt.println(r.trace)
	testing.expect(t, r.ok, r.message)
}
