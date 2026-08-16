package kernel
import "../asm_helpers"
import "../lib/acpi"
import "../lib/elf"
import "../lib/lmem"
import "../lib/shared"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"

ADAM_STACK_SIZE :: 16 * mem.Kilobyte

adam_init :: proc(adamImg: elf.Image, rsdp: ^acpi.Rsdp) {
	assert((adamImg.end - adamImg.base) > 0)

	print.serial_write("adam: starting init \n")

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
	{
		acpiRegions := collect_all_acpi_regions(rsdp)
		defer delete(acpiRegions)

		assert(acpiRegions != nil)

		for r in acpiRegions {
			start := pmm.addr_round_down_to_page(r.base)
			end := pmm.addr_round_up_to_page(r.base + r.size)

			for p := start; p < end; p += shared.PAGE_SIZE {
				pmm.map_page(newPML4, p, ._4KB, {.Present, .User, .NX})
			}
		}

	}
	stackPhys := pmm.alloc_zeroed(ADAM_STACK_SIZE + shared.PAGE_SIZE)
	print.kensure(stackPhys != 0, "adam_init: stack alloc failed")
	if stackPhys == 0 {
		pmm.pml4_destroy(newPML4)
		return
	}

	pmm.map_page(newPML4, stackPhys, ._4KB, {})

	usableStart := stackPhys + shared.PAGE_SIZE
	stackTop := usableStart + ADAM_STACK_SIZE - 8
	assert(stackTop % 16 == 8)
	for p := usableStart; p < stackTop; p += shared.PAGE_SIZE {
		pmm.map_page(newPML4, p, ._4KB, {.Present, .User, .Write, .NX})
	}

	domain, dErr := new(ProtectionDomain)
	print.kensure(dErr == nil, "adam_init: ProtectionDomain alloc failed")
	if dErr != nil {
		pmm.free_pages(stackPhys, ADAM_STACK_SIZE + shared.PAGE_SIZE)
		pmm.pml4_destroy(newPML4)
		return
	}
	allocs, allocMapErr := make(map[uintptr]Alloc, ALLOC_INITIAL_CAPACITY, context.allocator)
	if allocMapErr != nil {
		free(domain)
		pmm.free_pages(stackPhys, ADAM_STACK_SIZE + shared.PAGE_SIZE)
		pmm.pml4_destroy(newPML4)
		return
	}

	domain^ = ProtectionDomain {
		pml4  = newPML4,
		allocs = allocs,
	}

	_, adamAlloc, adamInserted, adamAllocErr := map_entry(&domain.allocs, uintptr(adamImg.base))
	print.kensure(adamAllocErr == nil && adamInserted, "adam_init: failed to track image allocation")
	if adamAllocErr != nil || !adamInserted {
		domain_destroy(domain)
		return
	}
	adamAlloc^ = Alloc {
		sizeBytes = pmm.pages_needed(adamImg.end - adamImg.base) * shared.PAGE_SIZE,
		pageSize  = ._4KB,
		pageFlags = {.Present, .User, .NX},
	}

	_, stackAlloc, stackInserted, stackAllocErr := map_entry(&domain.allocs, uintptr(stackPhys))
	print.kensure(stackAllocErr == nil && stackInserted, "adam_init: failed to track stack allocation")
	if stackAllocErr != nil || !stackInserted {
		domain_destroy(domain)
		return
	}
	stackAlloc^ = Alloc {
		sizeBytes = ADAM_STACK_SIZE + shared.PAGE_SIZE,
		pageSize  = ._4KB,
		pageFlags = {.Present, .User, .Write, .NX},
	}

	savedState := saved_state_fresh(adamImg.entry, stackTop)
	savedState.rdi = u64(uintptr(rsdp))
	exec := execution_create(domain, savedState)
	print.kensure(exec != nil, "adam_init: Execution alloc failed")
	if exec == nil {
		domain_destroy(domain)
		return
	}

	idx := u32(intrinsics.atomic_add(&rrCpuNext, 1)) % u32(len(cpus))
	execution_enqueue(exec, &cpus[idx])

	print.serial_write("adam: began execution \n")

}

collect_all_acpi_regions :: proc(rsdp: ^acpi.Rsdp) -> (regs: [dynamic]acpi.Region) {
	print.kensure(rsdp != nil, "rsdp pointer nil, cannot find any device")


	regs = make([dynamic]acpi.Region, context.allocator)


	_, aErr := append(
		&regs,
		acpi.Region{base = u64(uintptr(rsdp)), size = u64(size_of(acpi.Rsdp))},
	)
	print.kensure(aErr == nil)

	root: ^acpi.Header

	entryBytes: u32

	if rsdp.revision >= 2 {
		root = (^acpi.Header)(uintptr(rsdp.xsdtAddr))
		entryBytes = 8
	} else {
		root = (^acpi.Header)(uintptr(rsdp.rsdtAddr))
		entryBytes = 4
	}

	print.kensure(root != nil)
	print.kensure(entryBytes != 0)

	already_have :: proc(list: [dynamic]acpi.Region, base, size: u64) -> bool {

		for r in list {
			if r.base == base && r.size == size do return true
		}
		return false
	}

	append(&regs, acpi.Region{base = u64(uintptr(root)), size = u64(root.length)})
	print.kensure(root.length >= u32(size_of(acpi.Header)), "ACPI root table is shorter than its header")
	num := (root.length - u32(size_of(acpi.Header))) / entryBytes

	if num == 0 do return regs

	raw := intrinsics.ptr_offset((^u8)(rawptr(root)), size_of(acpi.Header))

	for i in 0 ..< num {
		addr: u64

		assert(entryBytes == 4 || entryBytes == 8)
		if entryBytes == 8 {
			addr = ([^]u64)(raw)[i]
		} else {
			addr = u64(([^]u32)(raw)[i])
		}
		if addr == 0 do continue

		hdr := (^acpi.Header)(uintptr(addr))
		if hdr == nil do continue

		base := u64(uintptr(hdr))
		size := u64(hdr.length)

		if !already_have(regs, base, size) {
			append(&regs, acpi.Region{base = base, size = size})
		}
	}

	return regs

}
