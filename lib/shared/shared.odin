package shared
import "core:mem"
FrameBuffer :: struct {
	base:   [^]u32,
	width:  u64,
	height: u64,
	stride: u64,
}
PAGE_SIZE :: 4096
KERNEL_PHYSICAL_MEM_LOCATION: int : -1
