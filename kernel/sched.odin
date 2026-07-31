package kernel
import ah "../asm_helpers"
import "../asm_helpers"
import "../lib/acpi"
import "../lib/shared"
import "../lib/spinlock"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"
SLICE_MS: u64 : 20
SLICE_WARN_MS: u64 : SLICE_MS - 2
KERNEL_STACK_PER_CPU_SIZE :: 16 * mem.Kilobyte
#assert(KERNEL_STACK_PER_CPU_SIZE % 16 == 0)

IdleHint :: enum u8 {
	Shallow = 0x00,
	C1E     = 0x10,
	Deep    = 0x40,
}


RunReason :: enum u8 {
	Expired,
	Faulted,
	Yielded,
}


Domain :: struct {
	pml4: u64,
}


CpuState :: struct {
	self:      ^CpuState,
	kernelRSP: u64,
	userRSP:   u64,
	runState:  ^SavedState,
	apicId:    u32,
}
SavedState :: struct #align (16) {
	rax, rbx, rcx, rdx:       u64, // 0,8,16,24
	rsi, rdi, rbp:            u64, // 32,40,48
	r8, r9, r10, r11:         u64, // 56,64,72,80
	r12, r13, r14, r15:       u64, // 88,96,104,112
	rip, cs, rflags, rsp, ss: u64, // 120,128,136,144,152
	fxsave:                   [512]u8, // 160 — must be 16-byte aligned
	valid:                    bool, // 672
}
#assert(offset_of(SavedState, rbx) == 8)
#assert(offset_of(SavedState, rip) == 120)
#assert(offset_of(SavedState, ss) == 152)
#assert(offset_of(SavedState, fxsave) == 160)
#assert(offset_of(SavedState, fxsave) % 16 == 0)
#assert(offset_of(SavedState, valid) == 672)

cpu0: CpuState
gKernelCtx: runtime.Context
gdts: []GDT
cpuStates: []^CpuState

sched_init :: proc(rsdp: ^acpi.Rsdp) {
	print.kensure(cpuid_has_sse3(), "CPU does not support SSE3 (MONITOR/MWAIT)")
	X2APIC_MSR_ID :: 0x802
	bspId := u32(ah.rdmsr_asm(0x802))
	apCount := acpi.collect_ap_ids(rsdp, bspId, nil)
	totalCores := int(apCount) + 1

	gdtsAlloc, allocErr := make([]GDT, totalCores)
	print.kensure(allocErr == nil, "OOM sched_init: gdts")
	gdts = gdtsAlloc
	gdt_tss_init(&gdts[0])
	cpu0.apicId = u32(bspId)

	cpuStatesAlloc, csErr := make([]^CpuState, totalCores)
	print.kensure(csErr == nil, "OOM sched_init: cpuStates")
	cpuStates = cpuStatesAlloc
	cpuStates[0] = &cpu0

	cpu_init(&cpu0, &gdts[0].tss.rsp[0])
	if apCount > 0 do smp_start(rsdp, apCount)
}
smp_start :: proc(rsdp: ^acpi.Rsdp, apCount: int) {
	bspId := u32(ah.rdmsr_asm(0x802))
	apIds, allocErr := make([]u32, apCount, context.allocator)
	print.kensure(allocErr == nil, "OOM smp_start")
	acpi.collect_ap_ids(rsdp, bspId, apIds)

	cr3 := ah.read_cr3()
	for apId in apIds {
		kernelStack, aErr := make([]byte, KERNEL_STACK_PER_CPU_SIZE + shared.PAGE_SIZE)
		print.kensure(aErr == nil, "smp_start: temp stack alloc failed")
		guardStart := u64(uintptr(raw_data(kernelStack)))
		pmm.map_page(pmm.kernelPML4, guardStart, ._4KB, {})
		stackStart := guardStart + shared.PAGE_SIZE
		for p := stackStart; p < stackStart + KERNEL_STACK_PER_CPU_SIZE; p += shared.PAGE_SIZE {
			pmm.map_page(pmm.kernelPML4, p, ._4KB, {.Present, .Write, .NX})
		}
		kernelStackTop := stackStart + KERNEL_STACK_PER_CPU_SIZE
		assert((kernelStackTop & 0xF) == 0)

		install_trampoline(
			rawptr(uintptr(pmm.trampolinePhys)),
			cr3,
			kernelStackTop,
			u64(uintptr(rawptr(ap_init))),
			kernelStackTop,
		)
		intrinsics.atomic_store(&apReady, 0)
		send_init_sipi(apId, pmm.trampolinePhys)
		for intrinsics.atomic_load(&apReady) == 0 {}
	}
}
nextGdtSlot: u32 = 1
apReady: u32
ap_init :: proc "c" () {
	ah.wrmsr_asm(u32(0xC0000100), gBootTlsEnd)
	context = gKernelCtx
	ah.lidt_asm(&GIDTDescriptor)
	slot := intrinsics.atomic_add(&nextGdtSlot, 1) - 1
	gdt_tss_init(&gdts[slot])
	cpu, allocErr := new(CpuState)
	print.kensure(allocErr == nil, "OOM ap_init")
	cpu.apicId = u32(ah.rdmsr_asm(0x802))
	cpu_init(cpu, &gdts[slot].tss.rsp[0])
	cpuStates[slot] = cpu
	intrinsics.atomic_store(&apReady, 1)
	idle_loop()
}
cpu_init :: proc(cpu: ^CpuState, tssRSP0: ^u64) {
	cpu.self = cpu
	kernelStack, aErr := make([]u8, KERNEL_STACK_PER_CPU_SIZE)
	print.kensure(aErr == nil, "cpu_init: allocation failure for kernel stack")
	cpu.kernelRSP = u64(uintptr(raw_data(kernelStack))) + KERNEL_STACK_PER_CPU_SIZE
	assert((cpu.kernelRSP & 0xF) == 0)
	tssRSP0^ = cpu.kernelRSP
	ah.gs_write_base(u64(uintptr(cpu)))
	cpu_syscall_init()
}
cpu_syscall_init :: proc() {
	IA32_EFER :: u32(0xC0000080); IA32_STAR :: u32(0xC0000081)
	IA32_LSTAR :: u32(0xC0000082); IA32_FMASK :: u32(0xC0000084)
	KERNELGSBASE :: u32(0xC0000102); IA32_GS_BASE :: u32(0xC0000101)
	EFER_SCE :: u64(1 << 0)
	ah.wrmsr_asm(IA32_EFER, ah.rdmsr_asm(IA32_EFER) | EFER_SCE)
	ah.wrmsr_asm(IA32_STAR, (u64(ah.USER_CS32) << 48) | (u64(ah.KERNEL_CS) << 32))
	ah.wrmsr_asm(IA32_LSTAR, u64(uintptr(rawptr(ah.syscall_entry))))
	ah.wrmsr_asm(IA32_FMASK, u64(0x200))
	ah.wrmsr_asm(KERNELGSBASE, ah.rdmsr_asm(IA32_GS_BASE))
}
