#+test

package kernel
import "../lib/shared"
import "core:slice"
import "pmm"
TEST_RAM_PAGES :: 128

test_kernel_init :: proc() -> (backing: []byte) {
	backing = make([]byte, TEST_RAM_PAGES * shared.PAGE_SIZE + shared.PAGE_SIZE - 1)
	pmm.directMapBase = pmm.addr_round_up_to_page(u64(uintptr(raw_data(backing))))
	k := &kernelState
	k^ = {}
	words := (TEST_RAM_PAGES + 63) / 64
	bitmapPages := pmm.pages_needed(words * size_of(u64))
	k.pmm.totalPages = TEST_RAM_PAGES
	k.pmm.bitmap = slice.from_ptr((^u64)(pmm.phys_to_ptr(shared.PAGE_SIZE)), words)
	assert(1 + bitmapPages < TEST_RAM_PAGES)

	slice.fill(k.pmm.bitmap, max(u64))
	pmm.bitmap_fill(&k.pmm, 1 + bitmapPages, TEST_RAM_PAGES, false)
	pmm.buddy_init(&k.pmm)
	k.heap.pmm = &k.pmm
	k.pcidAllocator.next = 2
	return backing
}
