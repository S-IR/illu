package kernel
import "../lib/lmem"
import "../lib/syscalls"

MemoryResourceFlag :: enum {
	Multiplexed,
	Volatile,
	InterruptSource,
}

MemoryResourceFlags :: bit_set[MemoryResourceFlag;u64]

MemoryResource :: struct {
	overlay:      syscalls.MemRegion,
	overlayFlags: MemoryResourceFlags,
	underlay:     ^MemoryUnderlay,
}

resource_init :: proc(
	phys, size: u64,
	pageSize: lmem.PageSize,
	pageFlags: lmem.PageFlags,
	flags: MemoryResourceFlags,
	backend: MemorySlotBackend,
) -> MemoryResource {
	return MemoryResource {
		overlay = {
			phys = phys,
			logical = phys,
			size = size,
			pageSize = pageSize,
			flags = pageFlags,
		},
		overlayFlags = flags,
		underlay = memory_underlay_create(phys, size, backend),
	}
}
