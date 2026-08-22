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
MMIO_FLAGS :: lmem.PageFlags{.Present, .User, .Write, .PWT, .PCD, .NX}

CONFIG_FLAGS :: MMIO_FLAGS

adam_init :: proc(adamImg: elf.Image, pcies: [dynamic]pci.Device) {
	assert((adamImg.end - adamImg.base) > 0)

	print.serial_write("adam: startineg init \n")

	newPML4 := pmm.alloc_zeroed(shared.PAGE_SIZE)
	print.kensure(newPML4 != 0, "adam_init: pml4 alloc failed")
	pmm.pml4_deep_copy(newPML4, pmm.kernelPML4, true)

	for seg in adamImg.segments {
		flags := lmem.PageFlags{.Present, .User, .NX}
		if .X in seg.perms do flags -= {.NX}
		if .W in seg.perms do flags += {.Write}

		phys := pmm.addr_round_down_to_page(seg.base)
		end := pmm.addr_round_up_to_page(seg.end)
		for phys < end {
			pmm.map_page(newPML4, phys, ._4KB, flags)
			phys += shared.PAGE_SIZE
		}
	}

	for device in pcies {
		configPage := pmm.addr_round_down_to_page(device.configBase)
		pmm.map_page(newPML4, configPage, ._4KB, CONFIG_FLAGS)

		for bar in device.bars {
			if !bar.isMemory || bar.addr == 0 || bar.size == 0 do continue

			start := pmm.addr_round_down_to_page(bar.addr)
			end := pmm.addr_round_up_to_page(bar.addr + bar.size)

			for addr := start; addr < end; addr += shared.PAGE_SIZE {
				pmm.map_page(newPML4, addr, ._4KB, MMIO_FLAGS)
			}

		}
	}

	{

		devicesPtr := raw_data(pcies)
		devicesBytes := u64(len(pcies)) * u64(size_of(pci.Device))

		start := pmm.addr_round_down_to_page(u64(uintptr(devicesPtr)))
		end := pmm.addr_round_up_to_page(u64(uintptr(devicesPtr)) + devicesBytes)


		for addr := start; addr < end; addr += shared.PAGE_SIZE {
			pmm.map_page(newPML4, addr, ._4KB, {.Present, .User, .Write, .NX})
		}
	}


	stackPhys := pmm.alloc_zeroed(ADAM_STACK_SIZE + shared.PAGE_SIZE)
	print.kensure(stackPhys != 0, "adam_init: stack alloc failed")


	pmm.map_page(newPML4, stackPhys, ._4KB, {})

	usableStart := stackPhys + shared.PAGE_SIZE
	stackTop := usableStart + ADAM_STACK_SIZE - 8
	assert(stackTop % 16 == 8)
	for p := usableStart; p < stackTop; p += shared.PAGE_SIZE {
		pmm.map_page(newPML4, p, ._4KB, {.Present, .User, .Write, .NX})
	}

	domain, dErr := new(ProtectionDomain)
	print.kensure(dErr == nil, "adam_init: ProtectionDomain alloc failed")

	allocs, allocMapErr := make(map[uintptr]Alloc, ALLOC_INITIAL_CAPACITY, context.allocator)
	print.kensure(allocMapErr == nil, "adam_init: failed to alloc adam alloc map")

	devices: [dynamic]PCIAddress
	devices, allocMapErr = make([dynamic]PCIAddress, len(pcies), context.allocator)
	print.kensure(allocMapErr == nil, "adam_init: failed to alloc adam devices array")

	for pcieDevice in pcies {
		append(
			&devices,
			PCIAddress {
				segment = pcieDevice.segment,
				bus = pcieDevice.bus,
				device = pcieDevice.device,
				function = pcieDevice.function,
			},
		)
	}
	domain^ = ProtectionDomain {
		pml4    = newPML4,
		allocs  = allocs,
		devices = devices,
	}

	_, adamAlloc, adamInserted, adamAllocErr := map_entry(&domain.allocs, uintptr(adamImg.base))
	print.kensure(
		adamAllocErr == nil && adamInserted,
		"adam_init: failed to track image allocation",
	)


	adamAlloc^ = Alloc {
		sizeBytes = pmm.pages_needed(adamImg.end - adamImg.base) * shared.PAGE_SIZE,
		pageSize  = ._4KB,
		pageFlags = {.Present, .User, .NX},
	}

	_, stackAlloc, stackInserted, stackAllocErr := map_entry(&domain.allocs, uintptr(stackPhys))
	print.kensure(
		stackAllocErr == nil && stackInserted,
		"adam_init: failed to track stack allocation",
	)

	stackAlloc^ = Alloc {
		sizeBytes = ADAM_STACK_SIZE + shared.PAGE_SIZE,
		pageSize  = ._4KB,
		pageFlags = {.Present, .User, .Write, .NX},
	}

	savedState := saved_state_fresh(adamImg.entry, stackTop)
	savedState.rdi = u64(uintptr(raw_data(pcies)))
	savedState.rsi = u64(len(pcies))
	exec := execution_create(domain, savedState)
	print.kensure(exec != nil, "adam_init: Execution alloc failed")

	idx := u32(intrinsics.atomic_add(&rrCpuNext, 1)) % u32(len(cpus))
	execution_enqueue(exec, &cpus[idx])

	print.serial_write("adam: began execution \n")

}
