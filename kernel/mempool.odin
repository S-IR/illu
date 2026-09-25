package kernel
import "../lib/spinlock"
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

memoryUnderlaysLock: spinlock.Spinlock

memory_underlay_create :: proc(phys, size: u64, backend: MemorySlotBackend) -> ^MemoryUnderlay {
	obj, err := new(MemoryUnderlay)
	print.kensure(err == nil, "memory_underlay_create: allocation failure")
	if err != {} do return nil
	obj^ = MemoryUnderlay {
		phys    = phys,
		size    = size,
		refs    = 1,
		backend = backend,
	}
	return obj
}

memory_underlay_increment :: proc(obj: ^MemoryUnderlay) {
	print.kassert(obj != nil, "memory_underlay_increment: nil object")
	if obj == nil do return
	spinlock.lock(&memoryUnderlaysLock)
	defer spinlock.unlock(&memoryUnderlaysLock)
	obj.refs += 1
}

memory_underlay_release :: proc(obj: ^MemoryUnderlay) {
	print.kassert(obj != nil, "memory_underlay_release: nil object")
	if obj == nil do return

	freed: MemoryUnderlay
	mustFree: bool
	{
		spinlock.lock(&memoryUnderlaysLock)
		defer spinlock.unlock(&memoryUnderlaysLock)
		print.kassert(obj.refs > 0, "memory_underlay_release: refcount underflow")
		obj.refs -= 1
		mustFree = obj.refs == 0
		if mustFree do freed = obj^
	}
	if !mustFree do return

	switch freed.backend {
	case .AllocatedRAM:
		pmm.free_pages(freed.phys, freed.size)
	case .ExternalPhysical, .DeviceMMIO:
	}
	free(obj)
}
