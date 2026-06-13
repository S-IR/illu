package ah

X86TableDescriptor :: struct #packed {
	limit: u16,
	base:  u64,
}

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


		apic_stub_table: [5]uintptr

	}

}
