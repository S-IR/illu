package ah

X86TableDescriptor :: struct #packed {
	limit: u16,
	base:  u64,
}
PIT_FREQ_HZ :: u32(1_193_182)
PIT_CMD_PORT :: u16(0x43)
PIT_CH2_PORT :: u16(0x42)
PIT_CH2_GATE :: u16(0x61)
when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		int3me :: proc() ---
		kernel_start_setup :: proc() ---
		halt :: proc() ---
		serial_init_asm :: proc() ---
		serial_write_byte_asm :: proc(c: u8) ---

		lgdt_asm :: proc(desc: ^X86TableDescriptor) ---
		reload_segments_asm :: proc() ---
		load_tss_asm :: proc(sel: u16) ---

		// CPU exception stubs — vectors 0-31
		isr_table: [32]uintptr

		// Hardware IRQ stubs — vectors 32-63
		irq_stub_table: [32]uintptr
		lidt_asm :: proc(desc: ^X86TableDescriptor) ---

		read_cr2 :: proc() -> u64 ---
		read_cr3 :: proc() -> u64 ---
		write_cr3 :: proc(addr: u64) ---

		wrmsr_asm :: proc(msr: u32, value: u64) ---
		rdmsr_asm :: proc(msr: u32) -> u64 ---

		rdtsc_asm :: proc() -> u64 ---
		apic_stub_table: [5]uintptr

		outb :: proc(port: u16, val: u8) ---
		inb :: proc(port: u16) -> u8 ---

		sti_asm :: proc() ---


	}
	pit_delay_us :: proc(us: u32) {
		ticks := u16(PIT_FREQ_HZ * us / 1_000_000)
		if ticks == 0 do ticks = 1
		outb(PIT_CH2_GATE, (inb(PIT_CH2_GATE) & ~u8(0x02)) | 0x01)
		outb(PIT_CMD_PORT, 0xB0)
		outb(PIT_CH2_PORT, u8(ticks & 0xFF))
		outb(PIT_CH2_PORT, u8(ticks >> 8))
		for inb(PIT_CH2_GATE) & 0x20 == 0 {}
	}
}
