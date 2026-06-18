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
buddy_alloc :: proc(order: u8) -> u64 {
	found := order
	for found < u8(PMM_BUDDY_MAX_ORDER) {
		if freeLists[found].next != &freeLists[found] do break
		found += 1
	}
	if found >= u8(PMM_BUDDY_MAX_ORDER) do return max(u64)

	blk := freeLists[found].next

	assert(blk != &freeLists[found])
	assert(blk.free)

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
buddy_free :: proc(addr: u64, order: u8) {
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
	list_add(order = currOrder, page = currPage) // correct

}
@(private)
buddy_add_range :: proc(start, end: u64) {
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
list_add :: proc(order: u8, page: u64) {
	assert(page != 0, "list_add: page 0 handed out")

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
list_remove :: proc(blk: ^FreeBlock) {
	assert(blk != nil)
	assert(blk.prev != nil)
	assert(blk.next != nil)

	assert(blk.prev.next == blk)
	print.serial_write("blk=")
	print.serial_write_hex(u64(uintptr(blk)))
	print.serial_write(" next=")
	print.serial_write_hex(u64(uintptr(blk.next)))
	print.serial_write(" next.prev=")
	print.serial_write_hex(u64(uintptr(blk.next.prev)))
	print.serial_writeln("")

	assert(blk.next.prev == blk)

	blk.prev.next = blk.next
	blk.next.prev = blk.prev

	blk.next = nil
	blk.prev = nil
	blk.free = false
}
