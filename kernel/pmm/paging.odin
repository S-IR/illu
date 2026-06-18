package pmm
import ah "../../asm_helpers"
import "../../lib/elf"
import "../../lib/shared"
import "../../uefi"
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
paging_init :: proc(
	kernelImg: elf.Image,
	memoryMap: [^]uefi.EFI_MEMORY_DESCRIPTOR,
	memoryMapSize: u64,
	memoryMapDescSize: u64,
) {
	head := &freeLists[0]
	print.serial_write("buddy sanity: head.next=")
	print.serial_write_hex(u64(uintptr(head.next)))
	print.serial_write(" head.prev=")
	print.serial_write_hex(u64(uintptr(head.prev)))
	print.serial_writeln("")
	if head.next != head {
		blk := head.next
		print.serial_write("first blk=")
		print.serial_write_hex(u64(uintptr(blk)))
		print.serial_write(" blk.prev=")
		print.serial_write_hex(u64(uintptr(blk.prev)))
		print.serial_write(" blk.next=")
		print.serial_write_hex(u64(uintptr(blk.next)))
		print.serial_writeln("")
	}

	enable_nxe()
	kernelPML4 = pmm_alloc_zeroed_page()

	entryCount := memoryMapSize / memoryMapDescSize
	desc_at :: #force_inline proc(
		m: [^]uefi.EFI_MEMORY_DESCRIPTOR,
		s: u64,
		i: u64,
	) -> ^uefi.EFI_MEMORY_DESCRIPTOR {
		return (^uefi.EFI_MEMORY_DESCRIPTOR)(uintptr(rawptr(m)) + uintptr(i * s))
	}
	usable :: #force_inline proc(t: uefi.EFI_MEMORY_TYPE) -> bool {
		return t == .ConventionalMemory || t == .LoaderCode || t == .LoaderData
	}

	print.serial_writeln("paging: pass1")
	for i in u64(0) ..< entryCount {
		desc := desc_at(memoryMap, memoryMapDescSize, i)
		if !usable(desc.Type) || desc.PhysicalStart == 0 do continue
		phys := desc.PhysicalStart
		end := phys + desc.NumberOfPages * shared.PAGE_SIZE
		for phys < end {
			map_page(kernelPML4, phys, ._4KB, PAGE_RW)
			phys += shared.PAGE_SIZE
		}
	}

	print.serial_writeln("paging: kernel perms")
	for seg in kernelImg.segments {
		flags := PageFlags{.Present, .NX}
		if .W in seg.perms {flags += {.Write}}
		if .X in seg.perms {flags -= {.NX}}
		phys := addr_round_down_to_page(seg.base)
		end := addr_round_up_to_page(seg.end)
		for phys < end {map_page(kernelPML4, phys, ._4KB, flags); phys += shared.PAGE_SIZE}
	}

	print.serial_writeln("paging: cr3 switch")
	ah.write_cr3(kernelPML4)

	print.serial_writeln("paging: pass2 huge pages")
	GB := u64(mem.Gigabyte)
	MB2 := u64(2 * mem.Megabyte)
	for i in u64(0) ..< entryCount {
		desc := desc_at(memoryMap, memoryMapDescSize, i)
		if !usable(desc.Type) || desc.PhysicalStart == 0 do continue
		phys := desc.PhysicalStart
		end := phys + desc.NumberOfPages * shared.PAGE_SIZE
		for phys < end {
			if cpuid_has_1gb_pages() &&
			   phys % GB == 0 &&
			   end - phys >= GB &&
			   block_is_free(phys, GB) {
				map_page(kernelPML4, phys, ._1GB, PAGE_RW); phys += GB; continue
			}
			if phys % MB2 == 0 && end - phys >= MB2 && block_is_free(phys, MB2) {
				map_page(kernelPML4, phys, ._2MB, PAGE_RW); phys += MB2; continue
			}
			phys += shared.PAGE_SIZE
		}
	}

	print.serial_writeln("paging: done")
}
cpuid_has_1gb_pages :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.EXTENDED_FEATURE_INFO, 0, &r)
	return (r.edx >> 26) & 1 == 1
}
@(private)
block_is_free :: proc(start: u64, size: u64) -> bool {
	start_page := start / shared.PAGE_SIZE
	end_page := (start + size) / shared.PAGE_SIZE
	for p in start_page ..< end_page {
		if p < state.totalPages && is_used(&state, p) {
			return false
		}
	}
	return true
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

		existing := transmute(PageFlags)pd[pdeIdx]
		if .Present in existing && .PS not_in existing {
			return
		}

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
