package kernel
import "../asm_helpers"
import "../lib/acpi"
import "../lib/elf"
import "../lib/lmem"
import "../lib/pci"
import "../lib/shared"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"

ADAM_STACK_SIZE :: 16 * mem.Kilobyte
CONFIG_FLAGS :: lmem.PageFlags{.Present, .User, .Write, .PWT, .PCD, .NX}

adam_init :: proc(adamImg: elf.Image, pcies: [dynamic]pci.Device) {
	assert((adamImg.end - adamImg.base) > 0)

	print.serial_write("adam: startineg init \n")

	newPML4 := pmm.alloc_zeroed(shared.PAGE_SIZE)
	print.kensure(newPML4 != 0, "adam_init: pml4 alloc failed")
	pmm.pml4_deep_copy(newPML4, pmm.kernelPML4, true)

	pd, dErr := new(ProtectionDomain)
	print.kensure(dErr == nil, "adam_init: ProtectionDomain alloc failed")
	pd.pml4 = newPML4
	protdomain_register(pd)

	for seg in adamImg.segments {
		flags := lmem.PageFlags{.Present, .User, .NX}
		if .X in seg.perms do flags -= {.NX}
		if .W in seg.perms do flags += {.Write}

		phys := pmm.addr_round_down_to_page(seg.base)
		end := pmm.addr_round_up_to_page(seg.end)
		for phys < end {
			pmm.map_page(newPML4, phys, phys, ._4KB, flags)
			resource: MemoryResource
			memory_resource_init(&resource, phys, shared.PAGE_SIZE, ._4KB, flags, {}, .AllocatedRAM)
			_, inserted := resource_insert(&pd.resources, resource)
			print.kensure(inserted, "adam_init: failed to track ELF page")
			phys += shared.PAGE_SIZE
		}
	}

	for device in pcies {
		configPage := pmm.addr_round_down_to_page(device.configBase)
		pmm.map_page(newPML4, configPage, configPage, ._4KB, CONFIG_FLAGS)
		resource: MemoryResource
		memory_resource_init(
			&resource,
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
		pmm.map_page(newPML4, addr, addr, ._4KB, {.Present, .User, .Write, .NX})
		resource: MemoryResource
		memory_resource_init(
			&resource,
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


	pmm.map_page(newPML4, stackPhys, stackPhys, ._4KB, {})
	{
		resource: MemoryResource
		memory_resource_init(&resource, stackPhys, shared.PAGE_SIZE, ._4KB, {}, {}, .AllocatedRAM)
		_, inserted := resource_insert(&pd.resources, resource)
		print.kensure(inserted, "adam_init: failed to track stack guard page")
	}

	usableStart := stackPhys + shared.PAGE_SIZE
	stackTop := usableStart + ADAM_STACK_SIZE - 8
	assert(stackTop % 16 == 8)
	for p := usableStart; p < stackTop; p += shared.PAGE_SIZE {
		pmm.map_page(newPML4, p, p, ._4KB, {.Present, .User, .Write, .NX})
		resource: MemoryResource
		memory_resource_init(
			&resource,
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
				pmm.map_page(newPML4, page, page, ._4KB, barFlags)
			}
			resource: MemoryResource
			memory_resource_init(
				&resource,
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

	savedState := saved_state_fresh(adamImg.entry, stackTop)
	savedState.rdi = u64(uintptr(raw_data(pcies)))
	savedState.rsi = u64(len(pcies))
	exec := execution_create(pd, savedState)
	print.kensure(exec != nil, "adam_init: Execution alloc failed")

	idx := u32(intrinsics.atomic_add(&rrCpuNext, 1)) % u32(len(cpus))
	execution_enqueue(exec, &cpus[idx])

	print.serial_write("adam: began execution \n")

}
