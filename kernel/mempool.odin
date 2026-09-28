package kernel
import "base:intrinsics"
import "pmm"
import "print"

MemorySlotBackend :: enum u32 {
	AllocatedRAM,
	ExternalPhysical,
	DeviceMMIO,
}

MemoryUnderlay :: struct {
	phys, size: u64,
	refs:       u32,
	backend:    MemorySlotBackend,
}

memory_underlay_create :: proc(phys, size: u64, backend: MemorySlotBackend) -> ^MemoryUnderlay {
	obj, err := new(MemoryUnderlay)
	print.kensure(err == nil, "memory_underlay_create: allocation failure")
	obj^ = MemoryUnderlay {
		phys    = phys,
		size    = size,
		refs    = 1,
		backend = backend,
	}
	return obj
}

memory_underlay_increment :: proc "contextless" (obj: ^MemoryUnderlay) {
	print.kassert(obj != nil, "memory_underlay_increment: nil object")
	previous := intrinsics.atomic_add_explicit(&obj.refs, 1, .Relaxed)
	print.kassert(previous > 0 && previous < max(u32), "memory_underlay_increment: dead or saturated")
}

memory_underlay_release :: proc(obj: ^MemoryUnderlay) {
	print.kassert(obj != nil, "memory_underlay_release: nil object")
	if obj == nil do return
	previous := intrinsics.atomic_sub_explicit(&obj.refs, 1, .Acq_Rel)
	print.kassert(previous > 0, "memory_underlay_release: refcount underflow")
	if previous != 1 do return

	switch obj.backend {
	case .AllocatedRAM:
		pmm.free_pages(obj.phys, obj.size)
	case .ExternalPhysical, .DeviceMMIO:
	}
	free(obj)
}
