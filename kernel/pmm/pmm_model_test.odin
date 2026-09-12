#+test
package pmm


import "../../lib/modelcheck"
import "../../lib/shared"
import "core:fmt"
import "core:mem"
import "core:testing"

TEST_PAGES :: 8
TEST_POOL_BYTES :: TEST_PAGES * shared.PAGE_SIZE
TEST_BITMAP_WORDS :: (TEST_PAGES + 63) / 64

TEST_State :: struct {
	pool:      [TEST_POOL_BYTES]u8,
	freeLists: [PMM_BUDDY_MAX_ORDER]FreeBlock,
	bitmap:    [TEST_BITMAP_WORDS]u64,
	outAddr:   [4]u64,
	outOrder:  [4]u8,
}

init_state :: proc() -> (testState: TEST_State) {
	backingRaw := make([]byte, TEST_POOL_BYTES + shared.PAGE_SIZE - 1)
	basePtr := uintptr(raw_data(backingRaw))

	aligned := (basePtr + uintptr(shared.PAGE_SIZE - 1)) & ~uintptr(shared.PAGE_SIZE - 1)
	buddyMapBase = u64(aligned)

	bitmapMem := make([]u64, TEST_BITMAP_WORDS)

	freeLists = {}
	state.bitmap = bitmapMem
	state.totalPages = TEST_PAGES
	for i in 0 ..< TEST_BITMAP_WORDS do state.bitmap[i] = max(u64)
	for pg in u64(1) ..< TEST_PAGES do kclear(&state, pg)

	buddy_init()
	s: TEST_State
	s.freeLists = freeLists
	mem.copy(&s.pool, rawptr(aligned), TEST_POOL_BYTES)
	copy(s.bitmap[:], state.bitmap)
	for i in 0 ..< 4 do s.outAddr[i] = max(u64)
	return s


}

TEST_NUM_ORDERS :: 4


buddy_next :: proc(s: TEST_State) -> []modelcheck.Transition(TEST_State) {
	out: [dynamic]modelcheck.Transition(TEST_State)


	slot := -1
	for i in 0 ..< 4 do if s.outAddr[i] == max(u64) {
		slot = i
		break
	}

	if slot != -1 {
		for order in u8(0) ..< TEST_NUM_ORDERS {
			restore(s)
			addr := buddy_alloc(order)
			if addr == max(u64) do continue
			ns := snapshot(s.outAddr, s.outOrder)
			ns.outAddr[slot] = addr
			ns.outOrder[slot] = order
			append(
				&out,
				modelcheck.Transition(TEST_State){ns, fmt.tprintf("alloc(order=%d)", order)},
			)
		}
	}

	for i in 0 ..< 4 {
		if s.outAddr[i] == max(u64) do continue
		restore(s)

		buddy_free(s.outAddr[i], s.outOrder[i])
		ns := snapshot(s.outAddr, s.outOrder)
		ns.outAddr[i] = max(u64)
		append(
			&out,
			modelcheck.Transition(TEST_State) {
				ns,
				fmt.tprintf("free(slot=%d, order=%d)", i, s.outOrder[i]),
			},
		)
	}
	return out[:]

}
inv :: proc(s: TEST_State) -> (ok: bool, msg: string) {
	bitmap := s.bitmap
	localPMM := PMM {
		bitmap     = bitmap[:],
		totalPages = TEST_PAGES,
		lock       = {},
	}

	expectedUsed: [TEST_PAGES]bool

	for i in 0 ..< 4 {
		if s.outAddr[i] == max(u64) do continue
		page := (s.outAddr[i] - buddyMapBase) / shared.PAGE_SIZE

		count := u64(1) << s.outOrder[i]
		for p in page ..< page + count {
			if expectedUsed[p] {
				return false, fmt.tprintf("two outstanding blocks overlap at page %d", p)
			}
			expectedUsed[p] = true
		}
	}

	for p in u64(1) ..< TEST_PAGES {
		used := is_used(&localPMM, p)
		if used != expectedUsed[p] {
			if expectedUsed[p] {
				return false, fmt.tprintf(
					"page %d belongs to a live allocation but the bitmap says free -- allocator could hand it to someone else too",
					p,
				)
			} else {
				return false, fmt.tprintf(
					"page %d is marked used but nothing holds it -- leaked, gone forever",
					p,
				)
			}
		}
	}
	return true, ""
}
@(test)
TestBuddyModel :: proc(t: ^testing.T) {
	init := init_state()
	r := modelcheck.run([]TEST_State{init}, buddy_next, inv)
	if !r.ok do fmt.println(r.trace)
	testing.expect(t, r.ok, r.message)
}
restore :: proc(s: TEST_State) {
	local := s
	freeLists = local.freeLists
	copy(state.bitmap, local.bitmap[:])
	mem.copy(rawptr(uintptr(buddyMapBase)), &local.pool, TEST_POOL_BYTES)
}

snapshot :: proc(outAddr: [4]u64, outOrder: [4]u8) -> TEST_State {
	ns: TEST_State
	ns.freeLists = freeLists
	copy(ns.bitmap[:], state.bitmap)
	mem.copy(&ns.pool, rawptr(uintptr(buddyMapBase)), TEST_POOL_BYTES)
	ns.outAddr = outAddr
	ns.outOrder = outOrder
	return ns
}
