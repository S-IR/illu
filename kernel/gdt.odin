
package kernel

import ah "../asm_helpers"
import "print"
GdtFlags :: bit_field u8 {
	avl:  bool | 1,
	long: bool | 1,
	db:   bool | 1,
	gran: bool | 1,
}
GdtEntry :: bit_field u64 {
	limitLow:  u16 | 16,
	baseLow:   u16 | 16,
	baseMid:   u8  | 8,
	access:    u8  | 8,
	limitHigh: u8  | 4,
	flags:     u8  | 4,
	baseHigh:  u8  | 8,
}

GdtAccess :: bit_field u8 {
	accessed: bool | 1,
	rw:       bool | 1,
	dc:       bool | 1,
	exec:     bool | 1,
	segment:  bool | 1,
	dpl:      u8   | 2,
	present:  bool | 1,
}
GDTEntryNames :: enum u8 {
	NullDesc,
	KernelCode,
	KernelData,
	UserCode32,
	UserData,
	UserCOde64,
	Tss1,
	Tss2,
}

@(private)
gdtEntries: [GDTEntryNames]u64

TSS :: struct #packed {
	_:         u32,
	rsp:       [3]u64,
	_:         u64,
	ist:       [7]u64,
	_:         [10]u8,
	iomapBase: u16,
}

@(private)
gdtTss: TSS

@(private)
GDTDescriptor: ah.X86TableDescriptor = {}


gdt_tss_init :: proc "contextless" () {
	make_flat_descriptor :: proc "contextless" (access: GdtAccess, flags: GdtFlags) -> u64 {
		e: GdtEntry
		e.limitLow = 0xFFFF
		e.limitHigh = 0xF
		e.access = transmute(u8)access
		e.flags = transmute(u8)flags
		return transmute(u64)e
	}


	tssBase := u64(uintptr(&gdtTss))

	tssLimit := u64(size_of(TSS) - 1)
	tss: GdtEntry
	tss.limitLow = u16(tssLimit)
	tss.baseLow = u16(tssBase)
	tss.baseMid = u8(tssBase >> 16)
	tss.access = transmute(u8)GdtAccess {
		present = true,
		dpl = 0,
		segment = false,
		exec = true,
		accessed = true,
	}

	tss.limitHigh = u8(tssLimit >> 16)
	tss.flags = 0
	tss.baseHigh = u8(tssBase >> 24)


	gdtEntries = {
		.NullDesc   = 0,
		.KernelCode = make_flat_descriptor(
			{present = true, segment = true, exec = true, rw = true, dpl = 0},
			{gran = true, long = true},
		),
		.KernelData = make_flat_descriptor(
			{present = true, segment = true, rw = true, dpl = 0},
			{gran = true, db = true},
		),
		.UserCode32 = make_flat_descriptor(
			{present = true, segment = true, rw = true, dpl = 3},
			{gran = true, db = true},
		),
		.UserData   = make_flat_descriptor(
			{present = true, segment = true, rw = true, dpl = 3},
			{gran = true, db = true},
		),
		.UserCOde64 = make_flat_descriptor(
			{present = true, segment = true, exec = true, rw = true, dpl = 3},
			{gran = true, long = true},
		),
		.Tss1       = transmute(u64)tss,
		.Tss2       = tssBase >> 32,
	}

	GDTDescriptor.base = u64(uintptr(&gdtEntries))
	GDTDescriptor.limit = u16(size_of(gdtEntries) - 1)

	ah.lgdt_asm(&GDTDescriptor)
	ah.reload_segments_asm()

	//1:10 PMClaude responded: SDM Vol 3A §3.SDM Vol 3A §3.4.2 "Segment Selectors":
	// Bits 15:3 = index into descriptor table, bits 2 = TI (0=GDT, 1=LDT), bits 1:0 = RPL.
	TSS_SEL :: u16(GDTEntryNames.Tss1) << 3
	ah.load_tss_asm(TSS_SEL)

	// print.serial_writeln("gdt: loaded")

}
