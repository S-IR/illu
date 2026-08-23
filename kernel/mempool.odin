package kernel
import "../lib/spinlock"
import "pmm"

MemorySlotBackend :: enum u32 {
	AllocatedRAM,
	ExternalPhysical,
	DeviceMMIO,
}
MemoryHandle :: struct {
	index:      int,
	generation: uint,
}
MemorySlot :: struct {
	phys, size: u64,
	generation: uint,
	refs:       u32,
	backend:    MemorySlotBackend,
}
memoryManager := struct {
	lock:      spinlock.Spinlock,
	slots:     [dynamic]MemorySlot,
	freeSlots: [dynamic]int,
}{}

MEM_SLOT_ARRAY_START_CAP :: 10
memory_slot_create :: proc(phys, size: u64, backend: MemorySlotBackend) -> MemoryHandle {
	spinlock.lock(&memoryManager.lock)
	defer spinlock.unlock(&memoryManager.lock)

	slotIdx: int = -1
	slot: ^MemorySlot = nil

	if memoryManager.slots == nil do memoryManager.slots = make([dynamic]MemorySlot, 0, MEM_SLOT_ARRAY_START_CAP)
	if memoryManager.freeSlots != nil && len(memoryManager.freeSlots) > 0 {
		assert(memoryManager.slots != nil)
		slotIdx = pop(&memoryManager.freeSlots)
		assert(len(memoryManager.slots) > slotIdx)

		slot = &memoryManager.slots[slotIdx]
	} else {
		append(&memoryManager.slots, MemorySlot{})
		slotIdx = len(memoryManager.slots) - 1
		slot = &memoryManager.slots[slotIdx]
	}

	assert(slot != nil)
	assert(slotIdx >= 0)

	slot.phys = phys
	slot.size = size
	assert(slot.refs == 0)
	slot.refs = 1
	slot.backend = backend
	slot.generation += 1

	return MemoryHandle{index = slotIdx, generation = slot.generation}
}
memory_slot_get :: proc(handle: MemoryHandle) -> ^MemorySlot {
	assert(memoryManager.slots != nil)
	if handle.index < 0 do return nil
	if handle.index >= len(memoryManager.slots) do return nil

	slot := &memoryManager.slots[handle.index]

	assert(slot.refs != 0)
	if slot.refs == 0 do return nil

	assert(slot.generation == handle.generation)
	if slot.generation != handle.generation do return nil

	return slot
}
memory_slot_increment :: proc(handle: MemoryHandle) -> bool {
	spinlock.lock(&memoryManager.lock)
	defer spinlock.unlock(&memoryManager.lock)

	slot := memory_slot_get(handle)
	if slot == nil do return false

	slot.refs += 1
	return true
}

memory_object_release :: proc(handle: MemoryHandle) {
	assert(memoryManager.slots != nil)


	objectToFree: MemorySlot = {}
	mustDoFree: bool
	{
		spinlock.lock(&memoryManager.lock)
		defer spinlock.unlock(&memoryManager.lock)


		slot := memory_slot_get(handle)
		assert(slot != nil)
		if slot == nil do return

		assert(slot.refs > 0)

		slot.refs -= 1
		mustDoFree = slot.refs == 0

		if !mustDoFree do return

		objectToFree = slot^
		if memoryManager.freeSlots == nil do memoryManager.freeSlots = make([dynamic]int, 0, MEM_SLOT_ARRAY_START_CAP)
		append(&memoryManager.freeSlots, handle.index)

		slot^.phys = 0
		slot^.size = 0
		slot^.backend = .AllocatedRAM

	}

	if !mustDoFree do return
	switch objectToFree.backend {
	case .AllocatedRAM:
		pmm.free_pages(objectToFree.phys, objectToFree.size)
	case .ExternalPhysical, .DeviceMMIO:
		return
	}

}
