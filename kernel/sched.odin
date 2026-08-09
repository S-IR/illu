package kernel
import ah "../asm_helpers"
import "../lib/acpi"
import "../lib/shared"
import "../lib/spinlock"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"

SLICE_MS: u64 : 20
KERNEL_STACK_PER_CPU_SIZE :: 16 * mem.Kilobyte
#assert(KERNEL_STACK_PER_CPU_SIZE % 16 == 0)


Alloc :: struct {
	phys:  u64,
	pages: u64,
}

ProtectionDomain :: struct {
	pml4:   u64,
	allocs: [dynamic]Alloc,
}

CpuState :: struct {
	self:               ^CpuState,
	kernelStackTop:     u64,
	userSyscallRsp:     u64,
	runState:           ^SavedState,
	schedulerResumeRsp: u64, // 32 -- saved mid-call %rsp inside domain_pick_and_enter; where run_abort jumps back to
	apicId:             u32,
	index:              u32,
	rrCurrent:          ^Execution,
	rrHead, rrTail:     ^Execution,
	rrLock:             spinlock.Spinlock,
	sleeping:           bool,
}
#assert(offset_of(CpuState, kernelStackTop) == 8)
#assert(offset_of(CpuState, userSyscallRsp) == 16)
#assert(offset_of(CpuState, runState) == 24)
#assert(offset_of(CpuState, schedulerResumeRsp) == 32)

SavedState :: struct #align (16) {
	rax, rbx, rcx, rdx:       u64,
	rsi, rdi, rbp:            u64,
	r8, r9, r10, r11:         u64,
	r12, r13, r14, r15:       u64,
	rip, cs, rflags, rsp, ss: u64,
	fxsave:                   [512]u8,
	valid:                    bool,
}
#assert(offset_of(SavedState, rbx) == 8)
#assert(offset_of(SavedState, rip) == 120)
#assert(offset_of(SavedState, ss) == 152)
#assert(offset_of(SavedState, fxsave) == 160)
#assert(offset_of(SavedState, fxsave) % 16 == 0)
#assert(offset_of(SavedState, valid) == 672)


MemRegion :: struct {
	phys, size: u64,
	flags:      pmm.PageFlags,
}
gKernelCtx: runtime.Context
gdts: []GDT
cpus: []CpuState
nextCPUSlot: u32 = 0
apReady: u32
sched_init :: proc(rsdp: ^acpi.Rsdp) {
	bspId := u32(ah.rdmsr_asm(0x802))
	apCount := acpi.collect_ap_ids(rsdp, bspId, nil)
	totalCores := int(apCount) + 1

	aErr: runtime.Allocator_Error
	gdts, aErr = make([]GDT, totalCores)
	print.kensure(aErr == nil, "OOM sched_init: gdts")

	gdts[0] = gdtBeforeSched
	gdt_tss_fill(&gdts[0])

	ah.lgdt_asm(&gdts[0].desc)
	ah.reload_segments_asm()
	TSS_SEL :: u16(GDTEntryNames.Tss1) << 3
	ah.load_tss_asm(TSS_SEL)

	cpus, aErr = make([]CpuState, totalCores)
	print.kensure(aErr == nil, "OOM sched_init: cpus")
	cpu_init(cpus, 0, bspId, &gdts[0].tss.rsp[0])

	ah.gs_write_base(u64(uintptr(&cpus[0]))) // AFTER alloc
	cpu_syscall_init() // AFTER alloc

	intrinsics.atomic_add(&nextCPUSlot, 1)
	if apCount > 0 do smp_start(rsdp, apCount)
}

smp_start :: proc(rsdp: ^acpi.Rsdp, apCount: int) {
	bspId := u32(ah.rdmsr_asm(0x802))
	apIds, allocErr := make([]u32, apCount, context.allocator)
	print.kensure(allocErr == nil, "OOM smp_start")
	acpi.collect_ap_ids(rsdp, bspId, apIds)

	cr3 := ah.read_cr3()
	for apId in apIds {
		cpuIndex := intrinsics.atomic_add(&nextCPUSlot, 1)

		gdt_tss_fill(&gdts[cpuIndex])
		cpu_init(cpus, cpuIndex, apId, &gdts[cpuIndex].tss.rsp[0])
		install_trampoline(
			rawptr(uintptr(pmm.trampolinePhys)),
			cr3,
			cpus[cpuIndex].kernelStackTop,
			u64(uintptr(rawptr(ap_init))),
			u64(uintptr(&cpus[cpuIndex])),
		)
		intrinsics.atomic_store(&apReady, 0)
		send_init_sipi(apId, pmm.trampolinePhys)
		for intrinsics.atomic_load(&apReady) == 0 {}
	}
}

ap_init :: proc "c" (cpu: ^CpuState) {
	ah.wrmsr_asm(u32(0xC0000100), gBootTlsEnd)
	context = gKernelCtx
	ah.lidt_asm(&GIDTDescriptor)

	ah.lgdt_asm(&gdts[cpu.index].desc)
	ah.reload_segments_asm()
	TSS_SEL :: u16(GDTEntryNames.Tss1) << 3
	ah.load_tss_asm(TSS_SEL)

	ah.gs_write_base(u64(uintptr(cpu)))
	intrinsics.atomic_store(&apReady, 1)

	cpu_syscall_init()
	cpu_idle_loop()
}

cpu_init :: proc(cpus: []CpuState, idx: u32, apicId: u32, tssRSP0: ^u64) {
	cpu := &cpus[idx]
	cpu.self = cpu
	cpu.apicId = apicId
	cpu.index = idx

	kernelStack, aErr := make([]u8, KERNEL_STACK_PER_CPU_SIZE + shared.PAGE_SIZE)
	print.kensure(aErr == nil, "cpu_init: allocation failure for kernel stack")

	paddedStart := u64(uintptr(raw_data(kernelStack)))
	end := paddedStart + u64(len(kernelStack))

	pmm.map_page(pmm.kernelPML4, paddedStart, ._4KB, {})
	for p := paddedStart + shared.PAGE_SIZE; p < end; p += shared.PAGE_SIZE {
		pmm.map_page(pmm.kernelPML4, p, ._4KB, {.NX, .Present, .Write})
	}

	cpu.kernelStackTop = end
	assert((cpu.kernelStackTop & 0xF) == 0)
	tssRSP0^ = cpu.kernelStackTop
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
saved_state_fresh :: proc(entryRip, entryRsp: u64) -> SavedState {
	return SavedState {
		rip = entryRip,
		rsp = entryRsp,
		cs = 0x2B,
		ss = 0x23,
		rflags = 0x202,
		fxsave = {},
		valid = true,
	}
}
