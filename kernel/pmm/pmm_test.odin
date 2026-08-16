#+test
package pmm
import "../../lib/shared"
import "core:testing"

@(test)
test_pmm :: proc(t: ^testing.T) {
	TEST_PAGES_COUNT :: u64(1024)
	backingRaw := make([]u8, TEST_PAGES_COUNT * shared.PAGE_SIZE + shared.PAGE_SIZE - 1)
	defer delete(backingRaw)
	basePtr := uintptr(raw_data(backingRaw))
	aligned := (basePtr + uintptr(shared.PAGE_SIZE - 1)) & ~uintptr(shared.PAGE_SIZE - 1)
	offset := aligned - basePtr
	backing := backingRaw[int(offset):int(offset) + int(TEST_PAGES_COUNT * shared.PAGE_SIZE)]
	when ODIN_TEST {
		buddyMapBase = u64(aligned)
	} else {
		//so that the lsp shuts up
		buddyMapBase: u64 = 0
	}

	bitmapWords := (TEST_PAGES_COUNT + 63) / 64
	bitmapMem := make([]u64, bitmapWords)
	defer delete(bitmapMem)
	state = {}
	freeLists = {}
	state.bitmap = bitmapMem
	state.totalPages = TEST_PAGES_COUNT
	for i in 0 ..< bitmapWords do state.bitmap[i] = max(u64)
	for pg in u64(1) ..< TEST_PAGES_COUNT do kclear(&state, pg)

	// This models the UEFI memory-map buffer: it is page-backed but was not
	// allocated by the buddy allocator, and its length need not be a power of 2.
	reclaimStart :: u64(100)
	reclaimEnd :: u64(107)
	for page in reclaimStart ..< reclaimEnd do kset(&state, page)

	buddy_init()

	buddy_release_range(reclaimStart, reclaimEnd)
	for page in reclaimStart ..< reclaimEnd do testing.expect(t, !is_used(&state, page))

	oom := palloc(TEST_PAGES_COUNT * shared.PAGE_SIZE * 2)
	testing.expect(t, oom == max(u64))

	#assert(TEST_PAGES_COUNT > 4)
	block4 := palloc(4 * shared.PAGE_SIZE)
	testing.expect(t, block4 != max(u64))
	page4 := (block4 - buddyMapBase) / shared.PAGE_SIZE
	testing.expect(t, page4 % 4 == 0)

	pfree(block4, 4 * shared.PAGE_SIZE)

	expectedFree :: TEST_PAGES_COUNT - 1
	allocs := make([dynamic]u64, 0, int(expectedFree))
	defer delete(allocs)

	for i in 0 ..< expectedFree {
		a := palloc(shared.PAGE_SIZE)
		testing.expect(t, a != max(u64))
		testing.expect(t, a != 0)
		testing.expect(t, a % shared.PAGE_SIZE == 0)
		for prev in allocs do testing.expect(t, prev != a)
		append(&allocs, a)
	}

	oom2 := palloc(shared.PAGE_SIZE)
	testing.expect(t, oom2 == max(u64))

	for a in allocs do pfree(a, shared.PAGE_SIZE)

	block4Again := palloc(4 * shared.PAGE_SIZE)
	testing.expect(t, block4Again != max(u64))
	page4Again := (block4Again - buddyMapBase) / shared.PAGE_SIZE
	testing.expect(t, page4Again % 4 == 0)
	pfree(block4Again, 4 * shared.PAGE_SIZE)

	clear(&allocs)
}
