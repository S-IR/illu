package kernel
import ah "../asm_helpers"
import "print"


lapic_init :: proc() {
	MSR_IA32_APIC_BASE :: u32(0x1B)
	MSR_APIC_BASE_MASK :: u64(0xFFFF_FFFF_F000)

	print.kensure(cpuid_has_x2apic(), "no x2apic available, required for the os")

	raw := ah.rdmsr_asm(MSR_IA32_APIC_BASE)
	flags := transmute(ApicBaseFlags)raw
	print.kensure(.EN in flags, "xapic not globally enabled, cannot upgrade to x2apic")
	flags += {.EN, .EXTD}
	ah.wrmsr_asm(MSR_IA32_APIC_BASE, transmute(u64)flags)
	VECTOR_APIC_SPURIOUS :: 0xFF

	svr := SvrRegister {
		vector = VECTOR_APIC_SPURIOUS,
		enable = true,
	}

	X2APIC_MSR_SVR :: u32(0x80F)


	ah.wrmsr_asm(X2APIC_MSR_SVR, u64(transmute(u32)svr))

	X2APIC_MSR_TPR :: u32(0x808)
	ah.wrmsr_asm(X2APIC_MSR_TPR, 0)

	masked := transmute(u32)LvtRegister{mask = true}
	X2APIC_MSR_LVT_TIMER :: u32(0x832)
	X2APIC_MSR_LVT_THERMAL :: u32(0x833)
	X2APIC_MSR_LVT_LINT0 :: u32(0x835)
	X2APIC_MSR_LVT_LINT1 :: u32(0x836)
	X2APIC_MSR_LVT_ERROR :: u32(0x837)

	ah.wrmsr_asm(X2APIC_MSR_LVT_TIMER, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_THERMAL, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_LINT0, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_LINT1, u64(masked))
	ah.wrmsr_asm(X2APIC_MSR_LVT_ERROR, u64(masked))


	idt_set_entry(VECTOR_APIC_TIMER, u64(ah.apic_stub_table[0]))
	idt_set_entry(VECTOR_APIC_ERROR, u64(ah.apic_stub_table[1]))
	idt_set_entry(VECTOR_APIC_THERMAL, u64(ah.apic_stub_table[2]))
	idt_set_entry(VECTOR_APIC_LINT0, u64(ah.apic_stub_table[3]))
	idt_set_entry(VECTOR_APIC_LINT1, u64(ah.apic_stub_table[4]))

	// ─── TSC calibration using your existing pit_delay_us ───

	calibrationMs := u64(10)
	tscStart := ah.rdtsc_asm()
	ah.pit_delay_us(u32(calibrationMs * 1000))
	tscEnd := ah.rdtsc_asm()

	print.kensure(tscEnd > tscStart, "TSC did not advance during PIT calibration")
	tscTicksPerMs = (tscEnd - tscStart) / calibrationMs

	print.kensure(cpuid_has_tsc_deadline(), "CPU does not support TSC-deadline mode")
	lvt := LvtTimerRegister {
		vector = u8(VECTOR_APIC_TIMER),
		mask   = false,
		mode   = .TscDeadline,
	}
	ah.wrmsr_asm(X2APIC_MSR_LVT_TIMER, u64(transmute(u32)lvt))

	ah.sti_asm()
	lapic_set_deadline(tscTicksPerMs * 1)

	print.serial_writeln("lapic: x2apic enabled, timer armed")
}

VECTOR_APIC_TIMER :: 0xF0
VECTOR_APIC_ERROR :: 0xF1
VECTOR_APIC_THERMAL :: 0xF2
VECTOR_APIC_LINT0 :: 0xF3
VECTOR_APIC_LINT1 :: 0xF4
ApicBaseFlag :: enum u64 {
	BSP  = 8,
	EN   = 11,
	EXTD = 10,
}
ApicBaseFlags :: bit_set[ApicBaseFlag;u64]

tscTicksPerMs: u64
TimerMode :: enum u8 {
	OneShot     = 0,
	Periodic    = 1,
	TscDeadline = 2,
}

LvtTimerRegister :: bit_field u32 {
	vector: u8        | 8,
	_:      u32       | 8,
	mask:   bool      | 1,
	mode:   TimerMode | 2,
	_:      u32       | 13,
}


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
	X2APIC_MSR_EOI :: u32(0x80B)
	ah.wrmsr_asm(X2APIC_MSR_EOI, 0)
}

lapic_set_deadline :: #force_inline proc(tsc_ticks: u64) {
	IA32_TSC_DEADLINE_MSR :: u32(0x6E0)
	ah.wrmsr_asm(IA32_TSC_DEADLINE_MSR, ah.rdtsc_asm() + tsc_ticks)
}
