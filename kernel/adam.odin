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
CONFIG_FLAGS :: lmem.PageFlags{.Present, .User, .Write, .PWT, .PCD, .NX}


adam_init :: proc(adamImg: elf.ElfImage, pcies: [dynamic]pci.Device) {
	assert((adamImg.end - adamImg.base) > 0)

	print.serial_write("adam: startineg init \n")


	writablePtrByAdam: ^byte = nil
	for seg in adamImg.segments {
		if .W in seg.perms {
			writablePtrByAdam = (^byte)(uintptr(seg.base))
		}
	}
	print.kensure(
		writablePtrByAdam != nil,
		"adam_init: cannot find 1 single writable byte by adam",
	)

	pd, _, dErr := protdomain_new(writablePtrByAdam)
	print.kensure(dErr == nil, "adam_init: ProtectionDomain alloc failed")


	for seg in adamImg.segments {
		flags := lmem.PageFlags{.Present, .User, .NX}
		if .X in seg.perms do flags -= {.NX}
		if .W in seg.perms do flags += {.Write}

		phys := pmm.addr_round_down_to_page(seg.base)
		end := pmm.addr_round_up_to_page(seg.end)
		for phys < end {
			pmm.map_page(pd.pml4, phys, phys, ._4KB, flags)
			resource := resource_init(phys, shared.PAGE_SIZE, ._4KB, flags, {}, .AllocatedRAM)
			_, inserted := resource_insert(&pd.resources, resource)
			print.kensure(inserted, "adam_init: failed to track ELF page")
			phys += shared.PAGE_SIZE
		}
	}

	for device in pcies {
		configPage := pmm.addr_round_down_to_page(device.configBase)
		pmm.map_page(pd.pml4, configPage, configPage, ._4KB, CONFIG_FLAGS)
		resource := resource_init(
			configPage,
			shared.PAGE_SIZE,
			._4KB,
			CONFIG_FLAGS,
			{.Volatile, .InterruptSource},
			.DeviceMMIO,
		)
		_, inserted := resource_insert(&pd.resources, resource)
		print.kensure(inserted, "adam_init: failed to track PCI config page")
	}


	devicesPtr := raw_data(pcies)
	devicesBytes := u64(len(pcies)) * u64(size_of(pci.Device))

	start := pmm.addr_round_down_to_page(u64(uintptr(devicesPtr)))
	end := pmm.addr_round_up_to_page(u64(uintptr(devicesPtr)) + devicesBytes)


	for addr := start; addr < end; addr += shared.PAGE_SIZE {
		pmm.map_page(pd.pml4, addr, addr, ._4KB, {.Present, .User, .Write, .NX})
		resource := resource_init(
			addr,
			shared.PAGE_SIZE,
			._4KB,
			{.Present, .User, .Write, .NX},
			{},
			.ExternalPhysical,
		)
		_, inserted := resource_insert(&pd.resources, resource)
		print.kensure(inserted, "adam_init: failed to track PCI device-list page")
	}


	stackPhys := pmm.alloc_zeroed(ADAM_STACK_SIZE + shared.PAGE_SIZE)
	print.kensure(stackPhys != 0, "adam_init: stack alloc failed")


	pmm.map_page(pd.pml4, stackPhys, stackPhys, ._4KB, {})
	{
		resource := resource_init(stackPhys, shared.PAGE_SIZE, ._4KB, {}, {}, .AllocatedRAM)
		_, inserted := resource_insert(&pd.resources, resource)
		print.kensure(inserted, "adam_init: failed to track stack guard page")
	}

	usableStart := stackPhys + shared.PAGE_SIZE
	stackTop := usableStart + ADAM_STACK_SIZE - 8
	assert(stackTop % 16 == 8)
	for p := usableStart; p < stackTop; p += shared.PAGE_SIZE {
		pmm.map_page(pd.pml4, p, p, ._4KB, {.Present, .User, .Write, .NX})
		resource := resource_init(
			p,
			shared.PAGE_SIZE,
			._4KB,
			{.Present, .User, .Write, .NX},
			{},
			.AllocatedRAM,
		)
		_, inserted := resource_insert(&pd.resources, resource)
		print.kensure(inserted, "adam_init: failed to track stack page")
	}

	for pcieDevice in pcies {
		for bar in pcieDevice.bars {
			if !bar.isMemory || bar.addr == 0 || bar.size == 0 do continue
			barStart := pmm.addr_round_down_to_page(bar.addr)
			barEnd := pmm.addr_round_up_to_page(bar.addr + bar.size)
			barFlags := lmem.PageFlags{.Present, .User, .Write, .PWT, .PCD, .NX}
			for page := barStart; page < barEnd; page += shared.PAGE_SIZE {
				pmm.map_page(pd.pml4, page, page, ._4KB, barFlags)
			}
			resource := resource_init(
				barStart,
				barEnd - barStart,
				._4KB,
				barFlags,
				{.Volatile},
				.DeviceMMIO,
			)
			_, inserted := resource_insert(&pd.resources, resource)
			print.kensure(inserted, "adam_init: failed to track PCI BAR resource")
		}
	}

	#assert(size_of(userschedule.UserSaveArea) <= shared.PAGE_SIZE)
	saveAreaPhys := pmm.alloc_zeroed(shared.PAGE_SIZE)
	print.kensure(saveAreaPhys != 0, "adam_init: save area alloc failed")
	saveAreaFlags := lmem.PageFlags{.Present, .User, .Write, .NX}
	pmm.map_page(pd.pml4, saveAreaPhys, saveAreaPhys, ._4KB, saveAreaFlags)
	{
		resource := resource_init(
			saveAreaPhys,
			shared.PAGE_SIZE,
			._4KB,
			saveAreaFlags,
			{},
			.AllocatedRAM,
		)
		_, inserted := resource_insert(&pd.resources, resource)
		print.kensure(inserted, "adam_init: failed to track save area page")
	}

	area := (^userschedule.UserSaveArea)(uintptr(saveAreaPhys))
	userschedule.save_area_init(area, adamImg.entry, stackTop)
	area.rdi = u64(syscalls.SchedulerEnterReason.Start)
	area.rsi = u64(uintptr(raw_data(pcies)))
	area.rdx = u64(len(pcies))
	area.rcx = saveAreaPhys

	grantErr := grant_spawn(pd, &cpus[0], area, adamImg.entry, userschedule.SCHED_WEIGHT_TOTAL)
	print.kensure(grantErr == .None, "adam_init: failed to spawn initial grant")

}
