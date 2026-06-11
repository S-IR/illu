package efi
import "base:intrinsics"

// Intel SDM Vol. 3A §4.5 Table 4-11 — IA-32e page table entry flags https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
PAGE_PRESENT :: u64(1 << 0)
PAGE_WRITE :: u64(1 << 1)
PAGE_HUGE :: u64(1 << 7)
PAGE_NO_CACHE :: u64(1 << 4)

// Intel SDM Vol. 3A §10.4.1 — LAPIC MMIO fixed base address https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
DIRECT_MAP_BASE :: u64(0xFFFF_8000_0000_0000)
LAPIC_PHYS :: u64(0xFEE0_0000)

// upper bound on page table pages needed:
// 1 PML4 + 2 PDPTs + up to 16 PDs (16GB max) = 19 pages; 32 is safe
PAGE_TABLE_POOL_PAGES :: 32

@(private)
bump: u64
@(private)
pool_base: u64

@(private)
alloc_zeroed_page :: proc "contextless" () -> u64 {
	addr := pool_base + bump * 4096
	bump += 1
	p := ([^]u64)(uintptr(addr))
	for i in 0 ..< 512 {
		p[i] = 0
	}
	return addr
}

// Intel SDM Vol. 3A §4.5 Fig. 4-8, Table 4-17 — PML4/PDPT/PD with 2-MB pages https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
build_page_tables :: proc "contextless" (
	bs: ^EFI_BOOT_SERVICES,
	memMap: [^]EFI_MEMORY_DESCRIPTOR,
	mapSize, descSize: u64,
) -> u64 {
	// allocate the pool in one EFI call
	pool: EFI_PHYSICAL_ADDRESS = 0
	status := bs.AllocatePages(.AllocateAnyPages, .LoaderData, PAGE_TABLE_POOL_PAGES, &pool)
	if status != EFI_SUCCESS || pool == 0 {
		return 0
	}
	pool_base = u64(pool)
	bump = 0

	// zero entire pool
	p := ([^]u8)(uintptr(pool_base))
	for i in 0 ..< PAGE_TABLE_POOL_PAGES * 4096 {
		p[i] = 0
	}

	pml4 := alloc_zeroed_page()

	// find highest physical address
	top_phys: u64 = 0
	entry_count := mapSize / descSize
	for i in u64(0) ..< entry_count {
		desc := intrinsics.ptr_offset((^EFI_MEMORY_DESCRIPTOR)(memMap), int(i))
		end := desc.PhysicalStart + desc.NumberOfPages * 4096
		if end > top_phys {
			top_phys = end
		}
	}
	// round up to 1GB; floor at 4GB to cover LAPIC/MMIO
	top_phys = (top_phys + 0x3FFF_FFFF) &~ u64(0x3FFF_FFFF)
	if top_phys < 0x1_0000_0000 {
		top_phys = 0x1_0000_0000
	}

	n_gb := top_phys >> 30

	pdpt_identity := alloc_zeroed_page()
	pdpt_direct := alloc_zeroed_page()

	pml4_arr := ([^]u64)(uintptr(pml4))
	pml4_arr[0] = pdpt_identity | PAGE_PRESENT | PAGE_WRITE
	pml4_arr[256] = pdpt_direct | PAGE_PRESENT | PAGE_WRITE

	pdpt_id_arr := ([^]u64)(uintptr(pdpt_identity))
	pdpt_dir_arr := ([^]u64)(uintptr(pdpt_direct))

	for g in u64(0) ..< n_gb {
		pd := alloc_zeroed_page()
		pd_arr := ([^]u64)(uintptr(pd))

		for e in u64(0) ..< 512 {
			phys := g * 0x4000_0000 + e * 0x20_0000
			flags := PAGE_PRESENT | PAGE_WRITE | PAGE_HUGE
			if phys == LAPIC_PHYS &~ u64(0x1F_FFFF) {
				flags |= PAGE_NO_CACHE
			}
			pd_arr[e] = phys | flags
		}

		// identity and direct map share the same PD pages
		pdpt_id_arr[g] = pd | PAGE_PRESENT | PAGE_WRITE
		pdpt_dir_arr[g] = pd | PAGE_PRESENT | PAGE_WRITE
	}

	return pml4
}
