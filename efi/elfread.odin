package efi

Elf64_Ehdr :: struct #packed {
	e_ident:     [16]u8,
	e_type:      u16,
	e_machine:   u16,
	e_version:   u32,
	eEntry:      u64,
	phOff:       u64,
	e_shoff:     u64,
	e_flags:     u32,
	e_ehsize:    u16,
	e_phentsize: u16,
	phNum:       u16,
	e_shentsize: u16,
	e_shnum:     u16,
	e_shstrndx:  u16,
}

Elf64Phdr :: struct #packed {
	p_type:   u32,
	p_flags:  u32,
	p_offset: u64,
	p_vaddr:  u64,
	p_paddr:  u64,
	p_filesz: u64,
	p_memsz:  u64,
	p_align:  u64,
}

PT_LOAD :: u32(1)
PT_DYNAMIC :: u32(2)
PF_W :: u32(2)
ELF_MAX_PHDRS :: 16

ET_EXEC :: u16(2)
ET_DYN :: u16(3)
EM_X86_64 :: u16(62)

Elf64Dyn :: struct #packed {
	tag: i64,
	val: u64,
}

Elf64Rela :: struct #packed {
	offset: u64,
	info:   u64,
	addend: i64,
}

DT_NULL :: i64(0)
DT_PLTRELSZ :: i64(2)
DT_RELA :: i64(7)
DT_RELASZ :: i64(8)
DT_RELAENT :: i64(9)
DT_RELRSZ :: i64(35)

R_X86_64_RELATIVE :: u64(8)

// Apply the dynamic relocations of a static PIE after its segments are in
// memory at `base`. Only R_X86_64_RELATIVE is valid for a fully static PIE
// (every entry: *(base + offset) = base + addend); any other relocation kind
// means the link produced something the loader cannot resolve — fail the load.
@(private)
apply_relative_relocs :: proc "contextless" (phdrs: []Elf64Phdr, base: u64) -> bool {
	dynVaddr, dynSize: u64
	for i in 0 ..< len(phdrs) {
		if phdrs[i].p_type == PT_DYNAMIC {
			dynVaddr = phdrs[i].p_vaddr
			dynSize = phdrs[i].p_memsz
			break
		}
	}
	if dynVaddr == 0 do return true // statically resolved, nothing to relocate

	relaAddr, relaSize: u64
	relaEnt := u64(size_of(Elf64Rela))
	dyn := ([^]Elf64Dyn)(uintptr(base + dynVaddr))
	count := dynSize / size_of(Elf64Dyn)
	for i in u64(0) ..< count {
		d := dyn[i]
		switch d.tag {
		case DT_NULL:
		case DT_RELA:
			relaAddr = d.val
		case DT_RELASZ:
			relaSize = d.val
		case DT_RELAENT:
			relaEnt = d.val
		case DT_PLTRELSZ, DT_RELRSZ:
			if d.val != 0 do return false // PLT/RELR relocations unsupported
		}
		if d.tag == DT_NULL do break
	}
	if relaAddr == 0 do return relaSize == 0
	if relaEnt != size_of(Elf64Rela) do return false

	relas := ([^]Elf64Rela)(uintptr(base + relaAddr))
	for i in u64(0) ..< relaSize / relaEnt {
		r := relas[i]
		RELA_TYPE_MASK :: u64(0xFFFF_FFFF)
		if r.info & RELA_TYPE_MASK != R_X86_64_RELATIVE do return false
		(^u64)(uintptr(base + r.offset))^ = u64(i64(base) + r.addend)
	}
	return true
}

LoadedImage :: struct {
	entry: u64, // absolute entry point (eEntry + base)
	base:  u64, // first byte of the image in memory (page-aligned)
	end:   u64, // one past the last byte (covers NOBITS: bss/stack)
	roEnd: u64, // end of the non-writable segments (text/rodata); base..roEnd may be mapped read-only
}

// Loads all PT_LOAD segments of an ELF file. The whole image span [base, end)
// is claimed from firmware with a single AllocatePages call, so the firmware
// memory map reflects real ownership and later firmware allocations can never
// land inside the image.
// pie=false: segments are placed at their absolute p_vaddr.
// pie=true:  firmware picks the location; segment vaddrs are offsets from it.
load_elf :: proc "contextless" (
	root: ^EFI_FILE_PROTOCOL,
	name: [^]u16,
	bs: ^EFI_BOOT_SERVICES,
	pie: bool = false,
) -> (
	img: LoadedImage,
	ok: bool,
) {
	PAGE_SIZE :: u64(4096)

	f: ^EFI_FILE_PROTOCOL
	if root.Open(root, &f, name, EFI_FILE_MODE_READ, 0) != EFI_SUCCESS do return {}, false
	defer f.Close(f)

	ehdr: Elf64_Ehdr
	sz := u64(size_of(Elf64_Ehdr))
	if f.Read(f, &sz, cast(^VOID)&ehdr) != EFI_SUCCESS do return {}, false
	if sz != size_of(Elf64_Ehdr) do return {}, false
	if ehdr.e_ident[0] != 0x7F ||
	   ehdr.e_ident[1] != 'E' ||
	   ehdr.e_ident[2] != 'L' ||
	   ehdr.e_ident[3] != 'F' {
		return {}, false
	}
	if ehdr.e_machine != EM_X86_64 do return {}, false
	if ehdr.e_type != (ET_DYN if pie else ET_EXEC) do return {}, false
	if ehdr.phNum == 0 || int(ehdr.phNum) > ELF_MAX_PHDRS do return {}, false

	phdrs: [ELF_MAX_PHDRS]Elf64Phdr
	if f.SetPosition(f, ehdr.phOff) != EFI_SUCCESS do return {}, false
	want := u64(ehdr.phNum) * u64(size_of(Elf64Phdr))
	sz = want
	if f.Read(f, &sz, cast(^VOID)&phdrs) != EFI_SUCCESS do return {}, false
	if sz != want do return {}, false

	minVaddr := ~u64(0)
	maxEnd, roEnd: u64
	for i in 0 ..< int(ehdr.phNum) {
		ph := &phdrs[i]
		if ph.p_type != PT_LOAD do continue
		if ph.p_filesz > ph.p_memsz do return {}, false
		if ph.p_vaddr < minVaddr do minVaddr = ph.p_vaddr
		segEnd := ph.p_vaddr + ph.p_memsz
		if segEnd > maxEnd do maxEnd = segEnd
		if ph.p_flags & PF_W == 0 && segEnd > roEnd do roEnd = segEnd
	}
	if maxEnd == 0 do return {}, false

	allocBase := minVaddr &~ (PAGE_SIZE - 1)
	pages := (maxEnd - allocBase + PAGE_SIZE - 1) / PAGE_SIZE

	base: u64
	if pie {
		addr: EFI_PHYSICAL_ADDRESS
		if bs.AllocatePages(.AllocateAnyPages, .LoaderData, pages, &addr) != EFI_SUCCESS {
			return {}, false
		}
		base = u64(addr) - allocBase
	} else {
		addr := EFI_PHYSICAL_ADDRESS(allocBase)
		if bs.AllocatePages(.AllocateAddress, .LoaderData, pages, &addr) != EFI_SUCCESS {
			return {}, false
		}
	}

	for i in 0 ..< int(ehdr.phNum) {
		ph := &phdrs[i]
		if ph.p_type != PT_LOAD do continue

		loadAddr := ph.p_vaddr + base
		mem := ([^]u8)(uintptr(loadAddr))
		for j in 0 ..< ph.p_memsz do mem[j] = 0

		if f.SetPosition(f, ph.p_offset) != EFI_SUCCESS do return {}, false
		sz = ph.p_filesz
		if f.Read(f, &sz, cast(^VOID)rawptr(uintptr(loadAddr))) != EFI_SUCCESS do return {}, false
		if sz != ph.p_filesz do return {}, false
	}

	if pie && !apply_relative_relocs(phdrs[:int(ehdr.phNum)], base) do return {}, false

	img = LoadedImage {
		entry = ehdr.eEntry + base,
		base  = allocBase + base,
		end   = maxEnd + base,
		roEnd = roEnd + base,
	}
	return img, true
}
