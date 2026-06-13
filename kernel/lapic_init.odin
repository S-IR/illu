package kernel
import ah "../asm_helpers"
import "print"
MSR_IA32_APIC_BASE :: u32(0x1B)
MSR_APIC_BASE_MASK :: u64(0xFFFF_FFFF_F000)

CPUID_LEAF_FEATURE_INFO :: 1 // CPUID leaf 1 gives feature flags in ECX
CPUID_FEAT_ECX_X2APIC :: 21 // bit 21 in ECX = x2APIC supported


ApicBaseFlag :: enum u64 {
	BSP  = 8,
	EN   = 11,
	EXTD = 10,
}
ApicBaseFlags :: bit_set[ApicBaseFlag;u64]

lapic_init :: proc() {
	r: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &r)
	print.serial_write("cpuid ecx=")
	print.serial_write_hex(u64(r.ecx))
	print.serial_writeln("")


	print.kensure(cpuid_has_x2apic(), "no x2apic available, required for the os")

	raw := ah.rdmsr_asm(MSR_IA32_APIC_BASE)
	flags := transmute(ApicBaseFlags)raw
	print.kensure(.EN in flags, "xapic not globally enabled, cannot upgrade to x2apic")
	flags += {.EN, .EXTD}
	ah.wrmsr_asm(MSR_IA32_APIC_BASE, transmute(u64)flags)

	svr := SvrRegister {
		vector = VECTOR_APIC_SPURIOUS,
		enable = true,
	}
	ah.wrmsr_asm(X2APIC_MSR_SVR, u64(transmute(u32)svr))

	// mask everything — nothing fires until we explicitly unmask it
	masked := transmute(u32)LvtRegister{mask = true}
	ah.wrmsr_asm(X2APIC_MSR_LVT_TIMER, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_THERMAL, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_LINT0, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_LINT1, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_ERROR, u64(masked))

	// install IDT entries for every APIC source
	// spurious doesn't need one since it should never fire with everything masked
	idt_set_entry(VECTOR_APIC_TIMER, u64(ah.apic_stub_table[0]))
	idt_set_entry(VECTOR_APIC_ERROR, u64(ah.apic_stub_table[1]))
	idt_set_entry(VECTOR_APIC_THERMAL, u64(ah.apic_stub_table[2]))
	idt_set_entry(VECTOR_APIC_LINT0, u64(ah.apic_stub_table[3]))
	idt_set_entry(VECTOR_APIC_LINT1, u64(ah.apic_stub_table[4]))
	print.serial_writeln("lapic: x2apic enabled")


}

X2APIC_MSR_EOI :: u32(0x80B)
X2APIC_MSR_SVR :: u32(0x80F)
X2APIC_MSR_LVT_TIMER :: u32(0x832)
X2APIC_MSR_LVT_THERMAL :: u32(0x833)
X2APIC_MSR_LVT_LINT0 :: u32(0x835)
X2APIC_MSR_LVT_LINT1 :: u32(0x836)
X2APIC_MSR_LVT_ERROR :: u32(0x837)

// vectors for APIC sources, above legacy PIC range (0x20-0x2F)
VECTOR_APIC_TIMER :: 0xF0
VECTOR_APIC_ERROR :: 0xF1
VECTOR_APIC_THERMAL :: 0xF2
VECTOR_APIC_LINT0 :: 0xF3
VECTOR_APIC_LINT1 :: 0xF4
VECTOR_APIC_SPURIOUS :: 0xFF // matches SVR

SvrRegister :: bit_field u32 {
	vector: u8   | 8,
	enable: bool | 1,
	_:      u32  | 23,
}

LvtRegister :: bit_field u32 {
	vector: u8   | 8,
	_:      u32  | 8,
	mask:   bool | 1,
	_:      u32  | 15,
}
lapic_send_eoi :: #force_inline proc() {
	ah.wrmsr_asm(X2APIC_MSR_EOI, 0)
}
