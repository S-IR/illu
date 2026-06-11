package ah

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		kernel_start_setup :: proc() ---
		halt :: proc() ---
		serial_init_asm :: proc() ---
		serial_write_byte_asm :: proc(c: u8) ---

	}

}
