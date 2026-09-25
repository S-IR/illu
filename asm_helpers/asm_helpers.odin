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
		kernel_start_setup :: proc() ---
		halt :: proc() -> ! ---
		serial_init_asm :: proc() ---
		serial_write_byte_asm :: proc(c: u8) ---

		lgdt_asm :: proc(desc: ^X86TableDescriptor) ---
		reload_segments_asm :: proc() ---
		load_tss_asm :: proc(sel: u16) ---

		isr_table: [32]uintptr
		irq_stub_table: [208]uintptr

		lidt_asm :: proc(desc: ^X86TableDescriptor) ---

		read_cr2 :: proc() -> u64 ---
		read_cr3 :: proc() -> u64 ---
		write_cr3 :: proc(addr: u64) ---
		read_cr4 :: proc() -> u64 ---
		write_cr4 :: proc(val: u64) ---

		invlpg_asm :: proc(addr: u64) ---
		verw_mitigate_asm :: proc() ---

		wrmsr_asm :: proc(msr: u32, value: u64) ---
		rdmsr_asm :: proc(msr: u32) -> u64 ---

		rdtsc_asm :: proc() -> u64 ---
		mmio_read_u8 :: proc(addr: rawptr) -> u8 ---
		mmio_read_u16 :: proc(addr: rawptr) -> u16 ---
		mmio_read_u32 :: proc(addr: rawptr) -> u32 ---
		mmio_write_u8 :: proc(addr: rawptr, value: u8) ---
		mmio_write_u16 :: proc(addr: rawptr, value: u16) ---
		mmio_write_u32 :: proc(addr: rawptr, value: u32) ---
		apic_stub_table: [6]uintptr

		outb :: proc(port: u16, val: u8) ---
		inb :: proc(port: u16) -> u8 ---
		cpu_pause :: proc() ---

		read_rbp :: proc() -> u64 ---

		invpcid_asm :: proc(type: u64, pcid: u64) ---
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

} else {

	kernel_start_setup :: proc "contextless" () {}
	halt :: proc "contextless" () -> ! {for {}}
	serial_init_asm :: proc "contextless" () {}
	serial_write_byte_asm :: proc "contextless" (c: u8) {}

	lgdt_asm :: proc "contextless" (desc: ^X86TableDescriptor) {}
	reload_segments_asm :: proc "contextless" () {}
	load_tss_asm :: proc "contextless" (sel: u16) {}

	isr_table: [32]uintptr
	irq_stub_table: [208]uintptr

	lidt_asm :: proc "contextless" (desc: ^X86TableDescriptor) {}

	read_cr2 :: proc "contextless" () -> u64 {return 0}
	read_cr3 :: proc "contextless" () -> u64 {return 0}
	write_cr3 :: proc "contextless" (addr: u64) {}

	read_cr4 :: proc "contextless" () -> u64 {return 0}
	write_cr4 :: proc "contextless" (val: u64) {}

	invlpg_asm :: proc "contextless" (addr: u64) {}
	verw_mitigate_asm :: proc "contextless" () {}

	wrmsr_asm :: proc "contextless" (msr: u32, value: u64) {}
	rdmsr_asm :: proc "contextless" (msr: u32) -> u64 {return 0}

	rdtsc_asm :: proc "contextless" () -> u64 {return 0}
	mmio_read_u8 :: proc "contextless" (addr: rawptr) -> u8 {return 0}
	mmio_read_u16 :: proc "contextless" (addr: rawptr) -> u16 {return 0}
	mmio_read_u32 :: proc "contextless" (addr: rawptr) -> u32 {return 0}
	mmio_write_u8 :: proc "contextless" (addr: rawptr, value: u8) {}
	mmio_write_u16 :: proc "contextless" (addr: rawptr, value: u16) {}
	mmio_write_u32 :: proc "contextless" (addr: rawptr, value: u32) {}
	apic_stub_table: [6]uintptr

	outb :: proc "contextless" (port: u16, val: u8) {}
	inb :: proc "contextless" (port: u16) -> u8 {return 0}
	cpu_pause :: proc "contextless" () {}


	invpcid_asm :: proc "contextless" (type: u64, pcid: u64) {}

	pit_delay_us :: proc "contextless" (us: u32) {}
	read_rbp :: proc "contextless" () -> u64 {return 0}
}
