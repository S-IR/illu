package alloc
import "../shared"
import "../spinlock"
import "base:intrinsics"
import "base:runtime"
import "core:mem"

HEAP_MAGIC :: u64(0x484541505F424C4B)
HEAP_FREE_MAGIC :: u64(0x465245455F424C4B)
BLOCK_HEADER_SIZE :: uintptr(64)
MIN_BLOCK_SIZE :: u64(16)

HeapBlock :: struct {
	magic:      u64,
	size:       u64,
	next, prev: ^HeapBlock,
	page:       ^HeapBlock,
}
heapFreeList: ^HeapBlock
heapLock: spinlock.Spinlock


heap_allocator :: proc() -> runtime.Allocator {
	return {procedure = heap_proc}
}
align_up :: proc(value, alignment: u64) -> u64 {
	return (value + alignment - 1) & ~(alignment - 1)
}
block_payload :: proc(block: ^HeapBlock) -> rawptr {
	assert(block != nil, "heap: nil block")
	assert(block.page != nil, "heap: block has no owning page")
	return rawptr(uintptr(block) + BLOCK_HEADER_SIZE)
}
block_from_payload :: proc(p: rawptr) -> ^HeapBlock {
	return (^HeapBlock)(uintptr(p) - BLOCK_HEADER_SIZE)
}


remove_free_block :: proc(block: ^HeapBlock) {
	assert(block != nil, "heap: removing nil free block")
	assert(block.magic == HEAP_FREE_MAGIC, "heap: removing allocated block")
	assert(block.page != nil, "heap: free block has no owning page")
	if block.prev != nil do assert(block.prev.next == block, "heap: broken previous link")
	if block.next != nil do assert(block.next.prev == block, "heap: broken next link")

	if block.prev != nil {
		block.prev.next = block.next
	} else {
		heapFreeList = block.next
	}
	if block.next != nil {
		block.next.prev = block.prev
	}
	block.next = nil
	block.prev = nil


}
insert_free_block :: proc(block: ^HeapBlock) {
	assert(block != nil, "heap: inserting nil free block")
	assert(block.magic == HEAP_FREE_MAGIC, "heap: inserting allocated block")
	assert(block.page != nil, "heap: free block has no owning page")
	assert(block.next == nil && block.prev == nil, "heap: free block already linked")

	block.magic = HEAP_FREE_MAGIC
	block.prev = nil
	block.next = heapFreeList

	if heapFreeList != nil {
		heapFreeList.prev = block
	}
	heapFreeList = block
}
new_heap_page :: proc() -> ^HeapBlock {
	addr := backend_alloc_pages(1)
	assert(addr != 0)
	assert(addr != max(u64))

	if addr == 0 || addr == max(u64) {
		return nil
	}

	block := (^HeapBlock)(uintptr(addr))
	assert(uintptr(addr) % uintptr(shared.PAGE_SIZE) == 0, "heap: unaligned heap page")
	block.magic = HEAP_FREE_MAGIC
	block.size = u64(shared.PAGE_SIZE) - u64(BLOCK_HEADER_SIZE)
	block.next = nil
	block.prev = nil
	block.page = block
	insert_free_block(block)
	return block
}
split_block :: proc(block: ^HeapBlock, requested: u64) {
	assert(block != nil, "heap: splitting nil block")
	assert(
		block.magic == HEAP_FREE_MAGIC || block.magic == HEAP_MAGIC,
		"heap: splitting invalid block",
	)
	assert(block.page != nil, "heap: block has no owning page")
	assert(requested % u64(BLOCK_HEADER_SIZE) == 0, "heap: unaligned split size")

	if block.size < requested {
		return
	}
	remaining := block.size - requested

	if remaining < u64(BLOCK_HEADER_SIZE) + MIN_BLOCK_SIZE {
		return
	}
	nextAddr := uintptr(block_payload(block)) + uintptr(requested)
	pageEnd := uintptr(rawptr(block.page)) + uintptr(shared.PAGE_SIZE)
	assert(nextAddr + BLOCK_HEADER_SIZE <= pageEnd, "heap: split exceeds page")

	next := (^HeapBlock)(nextAddr)
	next.magic = HEAP_FREE_MAGIC
	next.size = remaining - u64(BLOCK_HEADER_SIZE)
	next.prev = nil
	next.next = nil
	next.page = block.page

	block.size = requested
	insert_free_block(next)
}

find_free_block :: proc(size: u64) -> ^HeapBlock {
	block := heapFreeList

	for block != nil {
		assert(block.magic == HEAP_FREE_MAGIC, "heap: allocated block in free list")
		assert(block.page != nil, "heap: free block has no owning page")
		if block.next != nil do assert(block.next.prev == block, "heap: broken free list")
		if block.magic == HEAP_FREE_MAGIC && block.size >= size {
			return block
		}
		block = block.next
	}
	return nil
}

find_adjacent_blocks :: proc(block: ^HeapBlock) -> (prev, next: ^HeapBlock) {
	pageStart := block.page
	assert(pageStart != nil, "heap: block has no owning page")
	assert(
		uintptr(rawptr(pageStart)) % uintptr(shared.PAGE_SIZE) == 0,
		"heap: unaligned owning page",
	)
	pageEnd := uintptr(rawptr(pageStart)) + uintptr(shared.PAGE_SIZE)
	cursor := pageStart

	for cursor != block {
		assert(
			cursor.magic == HEAP_MAGIC || cursor.magic == HEAP_FREE_MAGIC,
			"heap: corrupt block metadata",
		)
		assert(cursor.page == pageStart, "heap: corrupt page metadata")

		nextAddr := uintptr(block_payload(cursor)) + uintptr(cursor.size)
		assert(
			nextAddr > uintptr(rawptr(cursor)) && nextAddr < pageEnd,
			"heap: corrupt block size",
		)
		prev = cursor
		cursor = (^HeapBlock)(nextAddr)
	}

	nextAddr := uintptr(block_payload(block)) + uintptr(block.size)
	if nextAddr < pageEnd {
		next = (^HeapBlock)(nextAddr)
		assert(next.page == pageStart, "heap: corrupt page metadata")
	}

	return prev, next
}

free_small_block :: proc(block: ^HeapBlock) {
	assert(block.magic == HEAP_MAGIC, "heap: invalid small allocation pointer")
	assert(block.page != nil, "heap: block has no owning page")
	current := block

	current.magic = HEAP_FREE_MAGIC
	current.next = nil
	current.prev = nil

	prev, next := find_adjacent_blocks(current)

	if next != nil && next.magic == HEAP_FREE_MAGIC {
		remove_free_block(next)
		current.size += u64(BLOCK_HEADER_SIZE) + next.size
	}

	if prev != nil && prev.magic == HEAP_FREE_MAGIC {
		remove_free_block(prev)
		prev.size += u64(BLOCK_HEADER_SIZE) + current.size
		current = prev
	}

	if current == current.page && current.size == u64(shared.PAGE_SIZE) - u64(BLOCK_HEADER_SIZE) {
		assert(current.next == nil && current.prev == nil, "heap: reclaimed block still linked")
		backend_free_pages(u64(uintptr(current.page)), 1)
		return
	}

	insert_free_block(current)
}
small_alloc :: proc(size: int, alignment: int, zeroed: bool) -> (rawptr, runtime.Allocator_Error) {
	align := u64(max(alignment, 1))
	if align > u64(BLOCK_HEADER_SIZE) {
		return nil, .Out_Of_Memory
	}

	requested := align_up(u64(size), u64(BLOCK_HEADER_SIZE))
	spinlock.lock(&heapLock)
	defer spinlock.unlock(&heapLock)

	block := find_free_block(requested)
	if block == nil {
		block = new_heap_page()
		if block == nil do return nil, .Out_Of_Memory
		block = find_free_block(requested)
		if block == nil do return nil, .Out_Of_Memory
	}

	remove_free_block(block)
	split_block(block, requested)

	block.magic = HEAP_MAGIC

	p := block_payload(block)
	if zeroed do intrinsics.mem_zero(p, size)
	return p, nil
}

large_alloc :: proc(size: int, zeroed: bool) -> (rawptr, runtime.Allocator_Error) {
	assert(size > 0)

	pages := max(u64(1), (u64(size) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE)

	addr := backend_alloc_pages(pages)

	if addr == 0 || addr == max(u64) {
		return nil, .Out_Of_Memory
	}

	p := rawptr(uintptr(addr))

	if zeroed do intrinsics.mem_zero(p, size)

	return p, nil
}

small_resize_in_place :: proc(old: rawptr, size: u64) -> bool {
	spinlock.lock(&heapLock)
	defer spinlock.unlock(&heapLock)

	block := block_from_payload(old)
	assert(block.magic == HEAP_MAGIC, "heap: invalid small allocation pointer")

	requested := align_up(size, u64(BLOCK_HEADER_SIZE))
	if requested > block.size {
		return false
	}

	split_block(block, requested)
	return true
}

heap_alloc :: proc(size: int, alignment: int, zeroed: bool) -> (rawptr, runtime.Allocator_Error) {
	if size == 0 {
		return nil, nil
	}

	assert(alignment >= 0, "heap: negative alignment")
	assert(
		alignment <= int(shared.PAGE_SIZE),
		"heap: alignment larger than page size is unsupported",
	)
	if alignment > 0 {
		assert(alignment & (alignment - 1) == 0, "heap: alignment must be a power of two")
	}

	if u64(size) < u64(shared.PAGE_SIZE) && u64(max(alignment, 1)) <= u64(BLOCK_HEADER_SIZE) {
		p, err := small_alloc(size, alignment, zeroed)

		if err == nil {
			return p, nil
		}
	}

	return large_alloc(size, zeroed)
}

heap_free :: proc(p: rawptr, oldSize: int) {
	if p == nil do return

	if uintptr(p) % uintptr(shared.PAGE_SIZE) == 0 {
		assert(oldSize > 0, "heap: invalid page allocation size")
		pages := max(u64(1), (u64(oldSize) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE)
		backend_free_pages(u64(uintptr(p)), pages)
		return
	}

	block := block_from_payload(p)

	switch block.magic {
	case HEAP_MAGIC:
		spinlock.lock(&heapLock)
		defer spinlock.unlock(&heapLock)
		free_small_block(block)
	case HEAP_FREE_MAGIC:
		assert(false, "heap: double free")
	case:
		assert(false, "heap: invalid allocation pointer")
	}
}


heap_proc :: proc(
	_: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old: rawptr,
	old_size: int,
	_: runtime.Source_Code_Location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	switch mode {
	case .Alloc:
		p, err := heap_alloc(size, alignment, true)

		if err != nil {
			return nil, err
		}

		return ([^]byte)(p)[:size], nil

	case .Alloc_Non_Zeroed:
		p, err := heap_alloc(size, alignment, false)

		if err != nil {
			return nil, err
		}

		return ([^]byte)(p)[:size], nil

	case .Free:
		heap_free(old, old_size)
		return nil, nil

	case .Resize:
		if old == nil {
			return heap_proc(nil, .Alloc, size, alignment, nil, 0, {})
		}

		if size == 0 {
			heap_free(old, old_size)
			return nil, nil
		}

		if uintptr(old) % uintptr(shared.PAGE_SIZE) == 0 {
			oldPages := max(u64(1), (u64(old_size) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE)
			newPages := max(u64(1), (u64(size) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE)
			if size >= int(shared.PAGE_SIZE) && oldPages == newPages {
				return ([^]byte)(old)[:size], nil
			}
		} else {
			if small_resize_in_place(old, u64(size)) {
				return ([^]byte)(old)[:size], nil
			}
		}

		p, err := heap_alloc(size, alignment, true)

		if err != nil {
			return nil, err
		}

		intrinsics.mem_copy(p, old, min(size, old_size))

		heap_free(old, old_size)

		return ([^]byte)(p)[:size], nil

	case .Resize_Non_Zeroed:
		if old == nil {
			return heap_proc(nil, .Alloc_Non_Zeroed, size, alignment, nil, 0, {})
		}

		if size == 0 {
			heap_free(old, old_size)
			return nil, nil
		}

		if uintptr(old) % uintptr(shared.PAGE_SIZE) == 0 {
			old_pages := max(u64(1), (u64(old_size) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE)
			new_pages := max(u64(1), (u64(size) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE)
			if size >= int(shared.PAGE_SIZE) && old_pages == new_pages {
				return ([^]byte)(old)[:size], nil
			}
		} else {
			if small_resize_in_place(old, u64(size)) {
				return ([^]byte)(old)[:size], nil
			}
		}

		p, err := heap_alloc(size, alignment, false)

		if err != nil {
			return nil, err
		}

		intrinsics.mem_copy(p, old, min(size, old_size))

		heap_free(old, old_size)

		return ([^]byte)(p)[:size], nil

	case .Query_Features:
		if s := (^runtime.Allocator_Mode_Set)(old); s != nil {
			s^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}

	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}

