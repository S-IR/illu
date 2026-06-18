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
cpu_syscall_init :: proc() {
	IA32_EFER :: u32(0xC0000080)
	IA32_STAR :: u32(0xC0000081)
	IA32_LSTAR :: u32(0xC0000082)
	IA32_FMASK :: u32(0xC0000084)
	KERNELGSBASE :: u32(0xC0000102)
	EFER_SCE :: u64(1 << 0)
	wrmsr_asm(IA32_EFER, rdmsr_asm(IA32_EFER) | EFER_SCE)
	wrmsr_asm(IA32_STAR, (u64(USER_CS32) << 48) | (u64(KERNEL_CS) << 32))
	wrmsr_asm(IA32_LSTAR, u64(uintptr(rawptr(syscall_entry))))
	wrmsr_asm(IA32_FMASK, u64(0x200))
	wrmsr_asm(KERNELGSBASE, 0)
}
