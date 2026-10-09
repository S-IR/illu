package shared
import "core:mem"
FrameBuffer :: struct {
	base:   [^]u32,
	width:  u64,
	height: u64,
	stride: u64,
}
api_check :: proc(ok: bool, loc := #caller_location) -> bool {
	assert(ok, loc = loc)
	return ok
}

PAGE_SIZE :: 4 * mem.Kilobyte
