
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

GDT :: struct {
	entries: [GDTEntryNames]u64,
	tss:     TSS,
	desc:    ah.X86TableDescriptor,
}

@(link_name = "_kernel_stack_top")
_kernel_stack_top: u8

gdt_tss_fill :: proc "contextless" (g: ^GDT) {
	// everything in gdt_tss_init EXCEPT the three asm calls at the end
	make_flat_descriptor :: proc "contextless" (access: GdtAccess, flags: GdtFlags) -> u64 {
		e: GdtEntry
		e.limitLow = 0xFFFF
		e.limitHigh = 0xF
		e.access = transmute(u8)access
		e.flags = transmute(u8)flags
		return transmute(u64)e
	}

	tssBase := u64(uintptr(&g.tss))
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

	g.entries = {
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

	g.desc.base = u64(uintptr(&g.entries))
	g.desc.limit = u16(size_of(g.entries) - 1)
}

gdt_tss_load :: proc "contextless" (g: ^GDT) {
	ah.lgdt_asm(&g.desc)
	ah.reload_segments_asm()
	TSS_SEL :: u16(GDTEntryNames.Tss1) << 3
	ah.load_tss_asm(TSS_SEL)
}
