package kernel
import "../asm_helpers"
import "../lib/elf"
import "../lib/shared"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"
ADAM_STACK_SIZE :: 16 * mem.Kilobyte

adam_init :: proc(adamImg: elf.Image) {
	assert((adamImg.end - adamImg.base) > 0)

	print.serial_write("adam: starting init \n")

	newPML4 := pmm.alloc_zeroed(shared.PAGE_SIZE)
	print.kensure(newPML4 != 0, "adam_init: pml4 alloc failed")
	pmm.pml4_deep_copy(newPML4, pmm.kernelPML4, true)

	for seg in adamImg.segments {
		flags := pmm.PageFlags{.Present, .User, .NX}
		if .X in seg.perms do flags -= {.NX}
		if .W in seg.perms do flags += {.Write}

		phys := pmm.addr_round_down_to_page(seg.base)
		end := pmm.addr_round_up_to_page(seg.end)
		for phys < end {
			pmm.map_page(newPML4, phys, ._4KB, flags)
			phys += shared.PAGE_SIZE
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
	stackTop := usableStart + ADAM_STACK_SIZE
	assert(stackTop % 16 == 0)
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
	domain^ = ProtectionDomain {
		pml4 = newPML4,
	}
	append(
		&domain.allocs,
		Alloc{phys = adamImg.base, pages = pmm.pages_needed(adamImg.end - adamImg.base)},
	)
	append(
		&domain.allocs,
		Alloc{phys = stackPhys, pages = (ADAM_STACK_SIZE + shared.PAGE_SIZE) / shared.PAGE_SIZE},
	)

	exec := execution_create(domain, saved_state_fresh(adamImg.entry, stackTop))
	print.kensure(exec != nil, "adam_init: Execution alloc failed")
	if exec == nil {
		domain_destroy(domain)
		return
	}

	idx := u32(intrinsics.atomic_add(&rrCpuNext, 1)) % u32(len(cpus))
	execution_enqueue(exec, &cpus[idx])

	print.serial_write("adam: began execution \n")

}
