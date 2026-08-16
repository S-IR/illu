package pmm
import "../print"
PMM_BUDDY_MAX_ORDER :: 19 //1gb
FreeBlock :: struct {
	next, prev: ^FreeBlock,
	free:       bool,
	order:      u8,
}
when ODIN_TEST {
	@(thread_local)
freeLists: [PMM_BUDDY_MAX_ORDER]FreeBlock
} else {
	freeLists: [PMM_BUDDY_MAX_ORDER]FreeBlock
}

@(private)
buddy_init :: proc() {
	for i in 0 ..< PMM_BUDDY_MAX_ORDER {
		freeLists[i].next = &freeLists[i]
		freeLists[i].prev = &freeLists[i]
	}
	p: u64 = 0

	for p < state.totalPages {
		if is_used(&state, p) {
			p += 1
			continue
		}
		end := p + 1
		for end < state.totalPages && !is_used(&state, end) {
			end += 1
		}
		buddy_add_range(p, end)
		p = end

	}
}
//max u64 is invalid
@(private)
buddy_alloc :: proc "contextless" (order: u8) -> u64 {
	found := order
	for found < u8(PMM_BUDDY_MAX_ORDER) {
		if freeLists[found].next != &freeLists[found] do break
		found += 1
	}
	if found >= u8(PMM_BUDDY_MAX_ORDER) do return max(u64)

	blk := freeLists[found].next

	print.kassert(blk != &freeLists[found])
	print.kassert(blk.free)

	list_remove(blk)

	page := rawptr_to_page(blk)

	for found > order {
		found -= 1
		list_add(found, page + (u64(1) << found))
	}

	for i in u64(0) ..< (u64(1) << order) {
		kset(&state, page + i)
	}
	return u64(uintptr(page_to_rawptr(page)))

}
@(private)
buddy_free :: proc "contextless" (addr: u64, order: u8) {
	page := rawptr_to_page(rawptr(uintptr(addr)))
	for i in u64(0) ..< (u64(1) << order) {
		kclear(&state, page + i)
	}

	currPage := page
	currOrder := order

	for currOrder < u8(PMM_BUDDY_MAX_ORDER) - 1 {
		buddyPage := currPage ~ (u64(1) << currOrder)
		if buddyPage == 0 do break
		if buddyPage + (u64(1) << currOrder) > state.totalPages do break
		if is_used(&state, buddyPage) do break


		buddyBlk := (^FreeBlock)(page_to_rawptr(buddyPage))
		if !buddyBlk.free || buddyBlk.order != currOrder do break


		list_remove(buddyBlk)
		currPage = min(currPage, buddyPage)
		currOrder += 1
	}
	list_add(order = currOrder, page = currPage)

}
// Release pages that were reserved outside the buddy allocator.  Unlike
// buddy_free, this must not round the range up: the pages may be adjacent to
// blocks that are already on a free list.
buddy_release_range :: proc "contextless" (start, end: u64) {
	print.kassert(start != 0)
	print.kassert(start < end)
	print.kassert(end <= state.totalPages)

	for page in start ..< end do kclear(&state, page)
	buddy_add_range(start, end)
}

@(private)
buddy_add_range :: proc "contextless" (start, end: u64) {
	p := start
	for p < end {
		order := u8(0)
		for order + 1 < u8(PMM_BUDDY_MAX_ORDER) {
			size := u64(1) << (order + 1)
			if p % size != 0 || size > end - p do break
			order += 1
		}

		list_add(order, p)
		p += u64(1) << order
	}
}
@(private)
list_add :: proc "contextless" (order: u8, page: u64) {
	print.kassert(page != 0, "list_add: page 0 handed out")

	blk := (^FreeBlock)(page_to_rawptr(page))
	blk.free = true
	blk.order = order

	head := &freeLists[order]
	blk.next = head.next
	blk.prev = head
	head.next.prev = blk
	head.next = blk
}
@(private)
list_remove :: proc "contextless" (blk: ^FreeBlock, caller := #caller_location) {
	print.kassert(blk != nil)
	print.kassert(blk.prev != nil)
	print.kassert(blk.next != nil)

	print.kassert(blk.prev.next == blk, "buddy: previous link mismatch", caller)
	print.kassert(blk.next.prev == blk, "buddy: next link mismatch", caller)

	blk.prev.next = blk.next
	blk.next.prev = blk.prev

	blk.next = nil
	blk.prev = nil
	blk.free = false
}
