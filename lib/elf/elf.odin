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

Hdr :: struct {
	eIdent:    [EI_NIDENT]u8,
	type:      enum Half {
		None,
		Rel,
		Exec,
		Dyn,
		Core,
		Loproc,
		Hiproc,
	},
	machine:   enum Half {
		X86_64 = 62,
	},
	version:   Word,
	entry:     Addr,
	phoff:     Off,
	shoff:     Off,
	flags:     Word,
	ehsize:    Half,
	phentsize: Half,
	phnum:     Half,
	shentsize: Half,
	shnum:     Half,
	shstrndx:  Half,
}
PhdrFlag :: enum Word {
	X,
	W,
	R,
}
Phdr :: struct {
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


Segment :: struct {
	base:  u64,
	end:   u64,
	perms: bit_set[PhdrFlag;Word],
}
MAX_SEGMENTS :: 16
Image :: struct {
	entry:    u64,
	base:     u64,
	end:      u64,
	segments: [dynamic; MAX_SEGMENTS]Segment,
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
