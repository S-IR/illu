package pmm
import "../../lib/elf"
import "../../lib/shared"
import "../../lib/spinlock"
import "../../uefi"
import "../print"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
HeapFooterSize :: size_of(u64)
heap_allocator :: proc() -> runtime.Allocator {
	return {procedure = heap_proc}
}
pages_for_alloc :: proc(size: u64) -> u64 {
	return (size + HeapFooterSize + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE
}
@(private)
heap_proc :: proc(
	_: rawptr,
	mode: runtime.Allocator_Mode,
	size, _: int,
	old: rawptr,
	old_size: int,
	_: runtime.Source_Code_Location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size == 0 do return nil, nil
		pages := pages_for_alloc(u64(size))

		addr := palloc(pages * shared.PAGE_SIZE)
		if addr == 0 do return nil, .Out_Of_Memory
		p := rawptr(uintptr(addr))

		intrinsics.mem_zero(p, size)
		return ([^]byte)(p)[:size], nil

	case .Free:
		if old == nil do return nil, nil
		pages := pages_for_alloc(u64(old_size))
		pfree(u64(uintptr(old)), pages * shared.PAGE_SIZE)
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		if old == nil do return heap_proc(nil, .Alloc, size, 0, nil, 0, {})
		if size == 0 do return heap_proc(nil, .Free, 0, 0, old, old_size, {})

		oldPages := pages_for_alloc(u64(old_size))
		newPages := pages_for_alloc(u64(size))

		if oldPages == newPages {
			return ([^]byte)(old)[:size], nil
		}
		p, e := heap_proc(nil, .Alloc, size, 0, nil, 0, {})
		if e != nil do return nil, e

		intrinsics.mem_copy(raw_data(p), old, min(size, old_size))

		_, e = heap_proc(nil, .Free, 0, 0, old, old_size, {})
		if e != nil do return nil, e
		return p, nil
	case .Query_Features:
		if s := (^runtime.Allocator_Mode_Set)(old); s != nil {
			s^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
