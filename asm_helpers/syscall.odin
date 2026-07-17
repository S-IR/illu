package ah
USER_CS32 :: u16(0x18)
KERNEL_CS :: u16(0x08)
when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_write_base :: proc(base: u64) ---
		syscall_entry :: proc() ---

	}

}
