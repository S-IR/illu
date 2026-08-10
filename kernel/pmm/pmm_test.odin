#+test
package pmm
import "../../lib/shared"
import "core:testing"

HeapTestMemory :: struct {
	backing: []u8,
	bitmap:  []u64,
}

heap_test_init :: proc() -> HeapTestMemory {
	TEST_PAGES_COUNT :: u64(256)

	backingRaw := make([]u8, TEST_PAGES_COUNT * shared.PAGE_SIZE + shared.PAGE_SIZE - 1)
	basePtr := uintptr(raw_data(backingRaw))
	aligned := (basePtr + uintptr(shared.PAGE_SIZE - 1)) & ~uintptr(shared.PAGE_SIZE - 1)
	offset := aligned - basePtr
	when ODIN_TEST {
		buddyMapBase = u64(aligned)
	}

	bitmapWords := (TEST_PAGES_COUNT + 63) / 64
	bitmapMem := make([]u64, bitmapWords)
	state = {}
	freeLists = {}
	heapFreeList = nil
	heapLock = {}
	buddyInitialized = false
	state.bitmap = bitmapMem
	state.totalPages = TEST_PAGES_COUNT

	for i in 0 ..< bitmapWords {
		state.bitmap[i] = max(u64)
	}
	for pg in u64(1) ..< TEST_PAGES_COUNT {
		kclear(&state, pg)
	}

	buddy_init()
	return {backing = backingRaw, bitmap = bitmapMem}
}

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

	buddy_init()

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

@(test)
test_heap :: proc(t: ^testing.T) {
	testMemory := heap_test_init()
	defer delete(testMemory.backing)
	defer delete(testMemory.bitmap)

	small, err := heap_proc(nil, .Alloc, 24, 8, nil, 0, {})
	testing.expect(t, err == nil)
	for &b in small do b = 0xA5

	resizedSmall: []byte
	resizedSmall, err = heap_proc(
		nil,
		.Resize,
		48,
		8,
		raw_data(small),
		len(small),
		{},
	)
	testing.expect(t, err == nil)
	for b in resizedSmall[:len(small)] do testing.expect(t, b == 0xA5)
	heap_proc(nil, .Free, 0, 0, raw_data(resizedSmall), len(resizedSmall), {})

	reused: []byte
	reused, err = heap_proc(nil, .Alloc, 24, 8, nil, 0, {})
	testing.expect(t, err == nil)
	testing.expect(t, raw_data(reused) == raw_data(resizedSmall))
	heap_proc(nil, .Free, 0, 0, raw_data(reused), len(reused), {})

	a: []byte
	a, err = heap_proc(nil, .Alloc, 512, 8, nil, 0, {})
	testing.expect(t, err == nil)
	b: []byte
	b, err = heap_proc(nil, .Alloc, 512, 8, nil, 0, {})
	testing.expect(t, err == nil)
	c: []byte
	c, err = heap_proc(nil, .Alloc, 512, 8, nil, 0, {})
	testing.expect(t, err == nil)

	heap_proc(nil, .Free, 0, 0, raw_data(b), len(b), {})
	heap_proc(nil, .Free, 0, 0, raw_data(a), len(a), {})

	merged: []byte
	merged, err = heap_proc(nil, .Alloc, 900, 8, nil, 0, {})
	testing.expect(t, err == nil)
	testing.expect(t, raw_data(merged) == raw_data(a))

	heap_proc(nil, .Free, 0, 0, raw_data(merged), len(merged), {})
	heap_proc(nil, .Free, 0, 0, raw_data(c), len(c), {})

	pageAlloc: []byte
	pageAlloc, err = heap_proc(nil, .Alloc, int(shared.PAGE_SIZE), 8, nil, 0, {})
	testing.expect(t, err == nil)
	testing.expect(t, uintptr(raw_data(pageAlloc)) % shared.PAGE_SIZE == 0)

	resized: []byte
	resized, err = heap_proc(
		nil,
		.Resize,
		int(2 * shared.PAGE_SIZE),
		8,
		raw_data(pageAlloc),
		len(pageAlloc),
		{},
	)
	testing.expect(t, err == nil)
	testing.expect(t, uintptr(raw_data(resized)) % shared.PAGE_SIZE == 0)
	heap_proc(nil, .Free, 0, 0, raw_data(resized), len(resized), {})

	pages: [255]u64
	for i in 0 ..< len(pages) {
		pages[i] = palloc(shared.PAGE_SIZE)
		testing.expect(t, pages[i] != max(u64))
	}
	testing.expect(t, palloc(shared.PAGE_SIZE) == max(u64))
	for page in pages do pfree(page, shared.PAGE_SIZE)
}
