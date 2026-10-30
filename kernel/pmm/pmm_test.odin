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
		directMapBase = u64(aligned)
	} else {
		//so that the lsp shuts up
		directMapBase: u64 = 0
	}

	bitmapWords := (TEST_PAGES_COUNT + 63) / 64
	bitmapMem := make([]u64, bitmapWords)
	defer delete(bitmapMem)
	p: PMM
	p.bitmap = bitmapMem
	p.totalPages = TEST_PAGES_COUNT
	for i in 0 ..< bitmapWords do p.bitmap[i] = max(u64)
	for pg in u64(1) ..< TEST_PAGES_COUNT do kclear(&p, pg)

	// This models the UEFI memory-map buffer: it is page-backed but was not
	// allocated by the buddy allocator, and its length need not be a power of 2.
	reclaimStart :: u64(100)
	reclaimEnd :: u64(107)
	for page in reclaimStart ..< reclaimEnd do kset(&p, page)

	buddy_init(&p)

	buddy_release_range(&p, reclaimStart, reclaimEnd)
	for page in reclaimStart ..< reclaimEnd do testing.expect(t, !is_used(&p, page))

	oom := palloc(&p, TEST_PAGES_COUNT * shared.PAGE_SIZE * 2)
	testing.expect(t, oom == 0)

	#assert(TEST_PAGES_COUNT > 4)
	block4 := palloc(&p, 4 * shared.PAGE_SIZE)
	testing.expect(t, block4 != 0)
	page4 := block4 / shared.PAGE_SIZE
	testing.expect(t, page4 % 4 == 0)

	pfree(&p, block4, 4 * shared.PAGE_SIZE)

	expectedFree :: TEST_PAGES_COUNT - 1
	allocs := make([dynamic]u64, 0, int(expectedFree))
	defer delete(allocs)

	for i in 0 ..< expectedFree {
		a := palloc(&p, shared.PAGE_SIZE)
		testing.expect(t, a != 0)
		testing.expect(t, a % shared.PAGE_SIZE == 0)
		for prev in allocs do testing.expect(t, prev != a)
		append(&allocs, a)
	}

	oom2 := palloc(&p, shared.PAGE_SIZE)
	testing.expect(t, oom2 == 0)

	for a in allocs do pfree(&p, a, shared.PAGE_SIZE)

	block4Again := palloc(&p, 4 * shared.PAGE_SIZE)
	testing.expect(t, block4Again != 0)
	page4Again := block4Again / shared.PAGE_SIZE
	testing.expect(t, page4Again % 4 == 0)
	pfree(&p, block4Again, 4 * shared.PAGE_SIZE)

	clear(&allocs)
}
