package pmm
import ah "../../asm_helpers"
import "../../lib/elf"
import "../../lib/shared"
import "../print"
import "core:mem"
PageFlag :: enum u64 {
	Present = 0,
	Write   = 1,
	User    = 2,
	PWT     = 3,
	PCD     = 4,
	PS      = 7,
	NX      = 63,
}
PageFlags :: bit_set[PageFlag;u64]
#assert(size_of(PageFlags) == size_of(u64))

PAGE_RX :: PageFlags{.Present, .User}
PAGE_RW :: PageFlags{.Present, .User, .Write, .NX}
PAGE_R :: PageFlags{.Present, .User, .NX}
PAGE_MMIO :: PageFlags{.Present, .Write, .PWT, .PCD}

kernelPML4: u64
paging_init :: proc(kernelImg: elf.Image) {
	enable_nxe()

	kernelPML4 = pmm_alloc_zeroed_page()

	print.serial_write("kernelimg base: ")
	print.serial_write_hex(kernelImg.base)
	print.serial_write("kernelimg entry: ")
	print.serial_write_hex(kernelImg.entry)

	for seg in kernelImg.segments {
		print.serial_write("seg.base: ")
		print.serial_write_hex(seg.base)
		print.serial_write(" seg.end: ")
		print.serial_write_hex(seg.end)
		print.serial_writeln("")
		flags := PageFlags{.Present, .NX}
		if .W in seg.perms {flags += {.Write}}
		if .X in seg.perms {flags -= {.NX}}

		assert(seg.base >= kernelImg.base)
		virt := addr_round_down_to_page(seg.base)
		// assert(false, "what")

		assert(virt >= u64(shared.KERNEL_PHYSICAL_MEM_LOCATION))
		end := addr_round_up_to_page(seg.end)


		TWO_MB :: u64(2 * mem.Megabyte)

		for virt < end {
			remaining := end - virt

			if virt % TWO_MB == 0 && remaining >= TWO_MB {

				map_page(kernelPML4, virt, ._2MB, flags)
				virt += TWO_MB
			} else {
				map_page(kernelPML4, virt, ._4KB, flags)
				virt += shared.PAGE_SIZE
			}
		}
		// for virt := start; virt < end; virt += shared.PAGE_SIZE {
		// }

	}
	print.serial_write("rsp: ")
	print.serial_write_hex(ah.read_rsp())

	print.serial_writeln("")
	print.serial_writeln("before write_cr3")
	ah.write_cr3(kernelPML4)
	print.serial_writeln("after write_cr3")
}
PageSize :: enum {
	_4KB,
	_2MB,
	_1GB,
}
PT_SHIFT_PML4 :: u64(39)
PT_SHIFT_PDPT :: u64(30)
PT_SHIFT_PD :: u64(21)
PT_SHIFT_PT :: u64(12)
PT_INDEX_MASK :: u64(0x1FF)
ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)

map_page :: proc(pml4Idx: u64, phys: u64, size: PageSize, flags: PageFlags) {
	assert(phys % shared.PAGE_SIZE == 0)

	pml4eIdx := (phys >> PT_SHIFT_PML4) & PT_INDEX_MASK
	pdpteIdx := (phys >> PT_SHIFT_PDPT) & PT_INDEX_MASK
	pdeIdx := (phys >> PT_SHIFT_PD) & PT_INDEX_MASK
	pteIdx := (phys >> PT_SHIFT_PT) & PT_INDEX_MASK

	pml4 := ([^]u64)(uintptr(pml4Idx))

	if size == ._1GB {
		if .Present not_in transmute(PageFlags)pml4[pml4eIdx] {
			pml4[pml4eIdx] = pmm_alloc_zeroed_page() | transmute(u64)(PageFlags{.Present, .Write})
		}
		pdpt := ([^]u64)(uintptr(pml4[pml4eIdx] & ENTRY_ADDR_MASK))
		pdpt[pdpteIdx] = phys | transmute(u64)(flags + {.Present, .PS})
		return
	}

	pdpt := ensure_table(pml4, pml4eIdx)

	if size == ._2MB {
		if .Present not_in transmute(PageFlags)pdpt[pdpteIdx] {
			pdpt[pdpteIdx] = pmm_alloc_zeroed_page() | transmute(u64)(PageFlags{.Present, .Write})
		}
		pd := ([^]u64)(uintptr(pdpt[pdpteIdx] & ENTRY_ADDR_MASK))
		pd[pdeIdx] = phys | transmute(u64)(flags + {.Present, .PS})
		return
	}

	pd := ensure_table(pdpt, pdpteIdx)
	pt := ensure_table(pd, pdeIdx)
	pt[pteIdx] = phys | transmute(u64)(flags + {.Present})
}

ensure_table :: #force_inline proc(parent: [^]u64, index: u64) -> [^]u64 {
	if .Present not_in transmute(PageFlags)parent[index] {
		parent[index] = pmm_alloc_zeroed_page() | transmute(u64)(PageFlags{.Present, .Write})
	}
	return ([^]u64)(uintptr(parent[index] & ENTRY_ADDR_MASK))
}
ENTRY_ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)

pmm_alloc_zeroed_page :: proc() -> u64 {
	phys := pmm_alloc(shared.PAGE_SIZE)
	mem.zero(rawptr(uintptr(phys)), shared.PAGE_SIZE)
	return phys
}
enable_nxe :: proc() {
	EFER_MSR :: u32(0xC0000080)
	val := ah.rdmsr_asm(EFER_MSR)
	ah.wrmsr_asm(EFER_MSR, val | (1 << 11))
}
