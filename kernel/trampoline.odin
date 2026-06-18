package kernel
import ah "../asm_helpers"
import "../lib/shared"
import "core:mem"
import "print"
when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		trampoline_start :: proc() ---
		trampoline_end :: proc() ---
	}
	foreign _ {
		patch_cr3: u64
		patch_stack: u64
		patch_entry: u64
	}
} else {
	// dummy stubs for testing
	trampoline_start :: proc() {}
	trampoline_end :: proc() {}
	patch_cr3: u64
	patch_stack: u64
	patch_entry: u64
}


install_trampoline :: proc(dsyPhys: rawptr, cr3, stack, entry: u64) {
	src := rawptr(trampoline_start)
	size := int(uintptr(rawptr(trampoline_end)) - uintptr(src))
	print.kassert(size <= shared.PAGE_SIZE, "install_trampoline: trampoline larger than one page")

	mem.copy(dsyPhys, src, size)

	offCR3 := uintptr(rawptr(&patch_cr3)) - uintptr(src)
	offStack := uintptr(rawptr(&patch_stack)) - uintptr(src)
	offEntry := uintptr(rawptr(&patch_entry)) - uintptr(src)
	(^u64)(uintptr(dsyPhys) + offCR3)^ = cr3
	(^u64)(uintptr(dsyPhys) + offStack)^ = stack
	(^u64)(uintptr(dsyPhys) + offEntry)^ = entry

}
US_PER_MS :: 1000
tsc_delay_us :: proc(us: u64) {
	target := ah.rdtsc_asm() + (tscTicksPerMs * us) / US_PER_MS
	for ah.rdtsc_asm() < target {}
}


send_init_sipi :: proc(apicId: u8, trampolinePhys: u64) {
	INIT_DELAY_MS :: 10
	SIPI_DELAY_US :: 200
	X2APIC_MSR_ICR :: 0x830
	INIT_CMD :: 0x4500
	SIPI_CMD_BASE :: 0x4600
	vector := u8(trampolinePhys >> 12)
	sipiCmd := SIPI_CMD_BASE | u64(vector)

	ah.wrmsr_asm(X2APIC_MSR_ICR, (u64(apicId) << 32) | INIT_CMD)
	tsc_delay_us(INIT_DELAY_MS * US_PER_MS)
	ah.wrmsr_asm(X2APIC_MSR_ICR, (u64(apicId) << 32) | sipiCmd)
	tsc_delay_us(SIPI_DELAY_US)
	ah.wrmsr_asm(X2APIC_MSR_ICR, (u64(apicId) << 32) | sipiCmd)
	tsc_delay_us(SIPI_DELAY_US)
}
