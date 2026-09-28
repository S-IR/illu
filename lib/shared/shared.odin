package shared
import "core:mem"
FrameBuffer :: struct {
	base:   [^]u32,
	width:  u64,
	height: u64,
	stride: u64,
}
PAGE_SIZE :: 4 * mem.Kilobyte
