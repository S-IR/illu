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
		patch_cpu: u64
	}
} else {
	trampoline_start :: proc() {}
	trampoline_end :: proc() {}
	patch_cr3: u64
	patch_stack: u64
	patch_entry: u64
	patch_cpu: u64
	patch_ready: u64
}

install_trampoline :: proc(dsyPhys: rawptr, cr3, stack, entry, cpu: u64) {
	src := rawptr(trampoline_start)
	size := int(uintptr(rawptr(trampoline_end)) - uintptr(src))
	print.kassert(size <= shared.PAGE_SIZE, "install_trampoline: trampoline larger than one page")
	print.kensure(
		cr3 < u64(1) << 32,
		"install_trampoline: CR3 must fit in 32 bits for 32-bit AP bring-up",
	)
	print.kensure(
		u64(uintptr(dsyPhys)) < u64(1) << 32,
		"install_trampoline: trampoline page must be below 4 GiB",
	)
	print.kensure(stack != 0, "install_trampoline: stack is null")
	print.kensure(stack % 16 == 0, "install_trampoline: stack must be 16-byte aligned")
	print.kensure(entry != 0, "install_trampoline: entry is null")
	print.kensure(entry % 16 == 0, "install_trampoline: entry should be 16-byte aligned")
	print.kensure(cpu != 0, "install_trampoline: cpu is null")
	print.kensure(cpu % 16 == 0, "install_trampoline: cpu should be 16-byte aligned")

	mem.copy(dsyPhys, src, size)

	offCR3 := uintptr(rawptr(&patch_cr3)) - uintptr(src)
	offStack := uintptr(rawptr(&patch_stack)) - uintptr(src)
	offEntry := uintptr(rawptr(&patch_entry)) - uintptr(src)
	offCPU := uintptr(rawptr(&patch_cpu)) - uintptr(src)
	(^u64)(uintptr(dsyPhys) + offCR3)^ = cr3
	(^u64)(uintptr(dsyPhys) + offStack)^ = stack
	(^u64)(uintptr(dsyPhys) + offEntry)^ = entry
	(^u64)(uintptr(dsyPhys) + offCPU)^ = cpu
}

US_PER_MS :: 1000
tsc_delay_us :: proc(us: u64) {
	target := ah.rdtsc_asm() + (tscTicksPerMs * us) / US_PER_MS
	for ah.rdtsc_asm() < target {}
}

send_init_sipi :: proc(apicId: u8, trampolinePhys: u64) {
	X2APIC_MSR_ICR :: 0x830
	INIT_ASSERT :: 0xC500
	INIT_DEASSERT :: 0x8500
	SIPI_CMD_BASE :: 0x4600
	print.kensure(
		trampolinePhys % u64(4 * 1024) == 0,
		"send_init_sipi: trampoline must be 4 KiB aligned",
	)
	print.kensure(trampolinePhys >> 12 <= 0xFF, "send_init_sipi: SIPI vector must fit in 8 bits")
	vector := u8(trampolinePhys >> 12)
	sipiCmd := SIPI_CMD_BASE | u64(vector)

	ah.wrmsr_asm(X2APIC_MSR_ICR, (u64(apicId) << 32) | INIT_ASSERT)
	tsc_delay_us(10_000)
	ah.wrmsr_asm(X2APIC_MSR_ICR, (u64(apicId) << 32) | INIT_DEASSERT)
	tsc_delay_us(200) // 200 µs
	ah.wrmsr_asm(X2APIC_MSR_ICR, (u64(apicId) << 32) | sipiCmd)
	tsc_delay_us(200)
}
