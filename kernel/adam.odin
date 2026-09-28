package kernel
import "../lib/elf"
import "../lib/lmem"
import "../lib/pci"
import "../lib/shared"
import "../lib/syscalls"
import "../lib/userschedule"
import "core:mem"
import "pmm"
import "print"

ADAM_STACK_SIZE :: 16 * mem.Kilobyte
MMIO_FLAGS :: lmem.PageFlags{.Present, .User, .Write, .PWT, .PCD, .NX}
USER_DATA_FLAGS :: lmem.PageFlags{.Present, .User, .Write, .NX}


adam_init :: proc(adamImg: elf.ElfImage, pciesPhys: []pci.Device) {
	assert(adamImg.end > adamImg.base)
	print.serial_writeln("adam: starting init")

	writablePtrByAdam: ^byte = nil
	for seg in adamImg.segments {
		if .W in seg.perms do writablePtrByAdam = (^byte)(uintptr(seg.base))
	}
	print.kensure(writablePtrByAdam != nil, "adam_init: cannot find 1 single writable byte by adam")

	pd, dErr := protdomain_new(writablePtrByAdam)
	print.kensure(dErr == nil, "adam_init: ProtectionDomain alloc failed")
	pcies := pmm.phys_to_slice(pciesPhys)

	for seg in adamImg.segments {
		flags := lmem.PageFlags{.Present, .User, .NX}
		if .X in seg.perms do flags -= {.NX}
		if .W in seg.perms do flags += {.Write}
		adam_track_pages(pd, pmm.addr_round_down_to_page(seg.base), pmm.addr_round_up_to_page(seg.end), flags, {}, .AllocatedRAM)
	}

	for device in pcies {
		configPage := pmm.addr_round_down_to_page(device.configBase)
		adam_track_pages(pd, configPage, configPage + shared.PAGE_SIZE, MMIO_FLAGS, {.Volatile, .InterruptSource}, .DeviceMMIO)
	}

	devicesStart := u64(uintptr(raw_data(pciesPhys)))
	devicesEnd := devicesStart + u64(len(pcies)) * size_of(pci.Device)
	adam_track_pages(pd, pmm.addr_round_down_to_page(devicesStart), pmm.addr_round_up_to_page(devicesEnd), USER_DATA_FLAGS, {}, .ExternalPhysical)

	stackPhys := pmm.alloc_zeroed(ADAM_STACK_SIZE + shared.PAGE_SIZE)
	print.kensure(stackPhys != 0, "adam_init: stack alloc failed")
	usableStart := stackPhys + shared.PAGE_SIZE
	adam_track_pages(pd, stackPhys, usableStart, {}, {}, .AllocatedRAM)
	adam_track_pages(pd, usableStart, usableStart + ADAM_STACK_SIZE, USER_DATA_FLAGS, {}, .AllocatedRAM)
	stackTop := usableStart + ADAM_STACK_SIZE - 8
	assert(stackTop % 16 == 8)

	for pcieDevice in pcies {
		for bar in pcieDevice.bars {
			if !bar.isMemory || bar.size == 0 do continue
			assert(bar.addr != 0)
			barStart := pmm.addr_round_down_to_page(bar.addr)
			barEnd := pmm.addr_round_up_to_page(bar.addr + bar.size)
			pageSize := lmem.PageSize._4KB
			for size in ([]lmem.PageSize{._1GB, ._2MB}) {
				bytes := lmem.page_bytes(size)
				if page_size_usable(size) && barStart % bytes == 0 && (barEnd - barStart) % bytes == 0 {
					pageSize = size
					break
				}
			}
			resource := resource_init(barStart, barEnd - barStart, pageSize, MMIO_FLAGS, {.Volatile}, .DeviceMMIO)
			_, inserted := resource_insert(&pd.resources, resource)
			print.kensure(inserted, "adam_init: failed to track PCI BAR resource")
			detached: [dynamic]u64
			resource_map(pd.pml4, resource, &detached)
			assert(len(detached) == 0)
		}
	}

	#assert(size_of(userschedule.UserSaveArea) <= shared.PAGE_SIZE)
	saveAreaPhys := pmm.alloc_zeroed(shared.PAGE_SIZE)
	print.kensure(saveAreaPhys != 0, "adam_init: save area alloc failed")
	adam_track_pages(pd, saveAreaPhys, saveAreaPhys + shared.PAGE_SIZE, USER_DATA_FLAGS, {}, .AllocatedRAM)

	area := (^userschedule.UserSaveArea)(pmm.phys_to_ptr(saveAreaPhys))
	userschedule.save_area_init(area, adamImg.entry, stackTop)
	area.rdi = u64(syscalls.SchedulerEnterReason.Start)
	area.rsi = u64(uintptr(raw_data(pciesPhys)))
	area.rdx = u64(len(pciesPhys))
	area.rcx = saveAreaPhys

	userArea := (^userschedule.UserSaveArea)(uintptr(saveAreaPhys))
	grantErr := grant_spawn(pd, &cpus[0], userArea, adamImg.entry, userschedule.SCHED_WEIGHT_TOTAL)
	print.kensure(grantErr == .None, "adam_init: failed to spawn initial grant")

}

adam_track_pages :: proc(
	pd: ^ProtectionDomain,
	start, end: u64,
	flags: lmem.PageFlags,
	resourceFlags: MemoryResourceFlags,
	backend: MemorySlotBackend,
) {
	assert(start % shared.PAGE_SIZE == 0 && end % shared.PAGE_SIZE == 0 && start <= end)
	for page := start; page < end; page += shared.PAGE_SIZE {
		pmm.map_page(pd.pml4, page, page, ._4KB, flags)
		resource := resource_init(page, shared.PAGE_SIZE, ._4KB, flags, resourceFlags, backend)
		_, inserted := resource_insert(&pd.resources, resource)
		print.kensure(inserted, "adam_init: page tracked twice")
	}
}
