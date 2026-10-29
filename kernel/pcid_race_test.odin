#+test
package kernel

import "../lib/modelcheck"
import "core:fmt"
import "core:mem"
import "core:testing"

pcid_alloc_free :: proc(data: rawptr) {
	pcid := pcid_alloc()
	assert(pcid >= 2 && pcid < PCID_MAX)
	pcid_free(pcid)
}

@(test)
TestPcidRace :: proc(t: ^testing.T) {
	cpuHasPCID = true
	pcidAllocator.next = 2
	pcidAllocator.free = nil
	r := modelcheck.race_check(
		{bodies = {pcid_alloc_free, pcid_alloc_free}, data = mem.ptr_to_bytes(&pcidAllocator)},
	)
	if !r.ok do fmt.println(r.trace)
	testing.expect(t, r.ok, r.message)
}
