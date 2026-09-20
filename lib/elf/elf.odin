package elf

Addr :: u64
Off :: u64
Half :: u16
Word :: u32
Sword :: i32
Xword :: u64
Sxword :: i64

EI_NIDENT :: 16
ElfIdentIndex :: enum u8 {
	MAG0       = 0,
	MAG1       = 1,
	MAG2       = 2,
	MAG3       = 3,
	CLASS      = 4,
	DATA       = 5,
	VERSION    = 6,
	OSABI      = 7,
	ABIVERSION = 8,
	PAD        = 9,
}

ElfType :: enum u16 {
	None,
	Rel,
	Exec,
	Dyn,
	Core,
	Loproc,
	Hiproc,
}
ElfMachine :: enum u16 {
	X86_64 = 62,
}

ElfHdr :: struct #packed {
	eIdent:    [16]u8,
	type:      ElfType,
	machine:   ElfMachine,
	version:   u32,
	entry:     u64,
	phoff:     u64,
	shoff:     u64,
	flags:     u32,
	ehsize:    u16,
	phentsize: u16,
	phnum:     u16,
	shentsize: u16,
	shnum:     u16,
	shstrndx:  u16,
}
#assert(offset_of(ElfHdr, entry) == 24)
#assert(size_of(ElfHdr{}.machine) == size_of(u16))
#assert(size_of(ElfHdr) == 64)
PhdrFlag :: enum Word {
	X,
	W,
	R,
}
ElfPhdr :: struct #packed {
	type:   enum Word {
		Null    = 0,
		Load    = 1,
		Dynamic = 2,
		Interp  = 3,
		Note    = 4,
		Phdr    = 6,
		//...more
	},
	flags:  bit_set[PhdrFlag;Word],
	offset: Off,
	vaddr:  Addr,
	paddr:  Addr,
	filesz: Xword,
	memsz:  Xword,
	align:  Xword,
}


ElfSegment :: struct #packed {
	base:  u64,
	end:   u64,
	perms: bit_set[PhdrFlag;Word],
}
MAX_SEGMENTS :: 16
ElfImage :: struct {
	entry:    u64,
	base:     u64,
	end:      u64,
	segments: [dynamic; MAX_SEGMENTS]ElfSegment,
}

is_valid_elf :: proc "contextless" (ident: [EI_NIDENT]u8) -> bool {
	return(
		ident[ElfIdentIndex.MAG0] == 0x7f &&
		ident[ElfIdentIndex.MAG1] == 'E' &&
		ident[ElfIdentIndex.MAG2] == 'L' &&
		ident[ElfIdentIndex.MAG3] == 'F' \
	)
}
is_64bit :: proc "contextless" (ident: [EI_NIDENT]u8) -> bool {
	return ident[ElfIdentIndex.CLASS] == 2
}
#assert(size_of(ElfPhdr) == 56)
#assert(offset_of(ElfPhdr, type) == 0)


DynamicTag :: enum i64 {
	NULL     = 0,
	NEEDED   = 1,
	PLTRELSZ = 2,
	PLTGOT   = 3,
	HASH     = 4,
	STRTAB   = 5,
	SYMTAB   = 6,
	RELA     = 7,
	RELASZ   = 8,
	RELAENT  = 9,
}
DynamicEntry :: struct #packed {
	dTag: DynamicTag,
	dVal: u64,
}
RelaEntry :: struct #packed {
	rOffset: Addr,
	rInfo:   Xword,
	rAddend: Sxword,
}
RelaType :: enum u32 {
	NONE            = 0,
	DIRECT_64       = 1,
	PC_RELATIVE_32  = 2,
	GOT_PC_RELATIVE = 9,
	RELATIVE        = 8,
}

rela_type :: proc "contextless" (rInfo: Xword) -> RelaType {
	return RelaType(u32(rInfo & 0xFFFF_FFFF))
}

parse_elf :: proc(data: []u8) -> (image: ElfImage, ok: bool) {
	assert(false) // TODO: elf loading not implemented
	return image, false
}

elf_load_into_memory :: proc(image: ^ElfImage, data: []u8) -> (actualBase: u64, ok: bool) {
	assert(false) // TODO: elf loading not implemented
	return 0, false
}

elf_run :: proc(image: ^ElfImage, base: u64, arg0, arg1: u64) -> bool {
	assert(false) // TODO: elf loading not implemented
	return false
}
