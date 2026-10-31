package pmm
import "../../lib/shared"
import "../print"
PMM_BUDDY_MAX_ORDER :: 19 //1gb
FreeBlock :: struct {
	next, prev: ^FreeBlock,
	free:       bool,
	order:      u8,
}
buddy_init :: proc(p: ^PMM) {
	for i in 0 ..< PMM_BUDDY_MAX_ORDER {
		p.freeLists[i].next = &p.freeLists[i]
		p.freeLists[i].prev = &p.freeLists[i]
	}
	page: u64 = 0

	for page < p.totalPages {
		if is_used(p, page) {
			page += 1
			continue
		}
		end := page + 1
		for end < p.totalPages && !is_used(p, end) {
			end += 1
		}
		buddy_add_range(p, page, end)
		page = end

	}
}
@(private)
buddy_alloc :: proc "contextless" (p: ^PMM, order: u8) -> u64 {
	found := order
	for found < u8(PMM_BUDDY_MAX_ORDER) {
		if p.freeLists[found].next != &p.freeLists[found] do break
		found += 1
	}
	if found >= u8(PMM_BUDDY_MAX_ORDER) do return 0

	blk := p.freeLists[found].next

	print.kassert(blk != &p.freeLists[found])
	print.kassert(blk.free)

	list_remove(blk)

	page := ptr_to_phys(blk) / shared.PAGE_SIZE

	for found > order {
		found -= 1
		list_add(p, found, page + (u64(1) << found))
	}

	bitmap_fill(p, page, page + (u64(1) << order), true)
	return page * shared.PAGE_SIZE

}
@(private)
buddy_free :: proc "contextless" (p: ^PMM, addr: u64, order: u8) {
	page := addr / shared.PAGE_SIZE
	print.kassert(page % (u64(1) << order) == 0, "buddy_free: block misaligned for order")
	print.kassert(page + (u64(1) << order) <= p.totalPages, "buddy_free: block past end")
	when ODIN_DEBUG do print.kassert(bitmap_all_used(p, page, page + (u64(1) << order)), "buddy_free: page already free")
	bitmap_fill(p, page, page + (u64(1) << order), false)

	currPage := page
	currOrder := order

	for currOrder < u8(PMM_BUDDY_MAX_ORDER) - 1 {
		buddyPage := currPage ~ (u64(1) << currOrder)
		if buddyPage == 0 do break
		if buddyPage + (u64(1) << currOrder) > p.totalPages do break
		if is_used(p, buddyPage) do break


		buddyBlk := (^FreeBlock)(page_to_rawptr(buddyPage))
		if !buddyBlk.free || buddyBlk.order != currOrder do break


		list_remove(buddyBlk)
		currPage = min(currPage, buddyPage)
		currOrder += 1
	}
	list_add(p, order = currOrder, page = currPage)

}
// Release pages that were reserved outside the buddy allocator.  Unlike
// buddy_free, this must not round the range up: the pages may be adjacent to
// blocks that are already on a free list.
buddy_release_range :: proc "contextless" (p: ^PMM, start, end: u64) {
	print.kassert(start != 0)
	print.kassert(start < end)
	print.kassert(end <= p.totalPages)

	bitmap_fill(p, start, end, false)
	buddy_add_range(p, start, end)
}

@(private)
buddy_add_range :: proc "contextless" (p: ^PMM, start, end: u64) {
	for page := start; page < end; {
		order := largest_block_order(page, end)
		list_add(p, order, page)
		page += u64(1) << order
	}
}

@(private)
largest_block_order :: proc "contextless" (page, end: u64) -> u8 {
	print.kassert(page < end)
	order := u8(0)
	for order + 1 < u8(PMM_BUDDY_MAX_ORDER) {
		size := u64(1) << (order + 1)
		if page % size != 0 || size > end - page do break
		order += 1
	}
	return order
}
@(private)
list_add :: proc "contextless" (p: ^PMM, order: u8, page: u64) {
	print.kassert(page != 0, "list_add: page 0 handed out")

	blk := (^FreeBlock)(page_to_rawptr(page))
	blk.free = true
	blk.order = order

	head := &p.freeLists[order]
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
