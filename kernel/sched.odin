package kernel
import ah "../asm_helpers"
import "../lib/acpi"
import "../lib/lmem"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"
SLICE_MS: u64 : 20
KERNEL_STACK_PER_CPU_SIZE :: 16 * mem.Kilobyte
#assert(KERNEL_STACK_PER_CPU_SIZE % 16 == 0)


MemoryResourceFlag :: enum {
	Multiplexed,
	Volatile,
	InterruptSource,
}

MemoryResourceFlags :: bit_set[MemoryResourceFlag;u64]

MemoryResource :: struct {
	overlay:      syscalls.MemRegion,
	overlayFlags: MemoryResourceFlags,
	underlay:     ^MemoryUnderlay,
}

resource_init :: proc(
	phys, size: u64,
	pageSize: lmem.PageSize,
	pageFlags: lmem.PageFlags,
	flags: MemoryResourceFlags,
	backend: MemorySlotBackend,
) -> MemoryResource {
	return MemoryResource {
		overlay = {
			phys = phys,
			logical = phys,
			size = size,
			pageSize = pageSize,
			flags = pageFlags,
		},
		overlayFlags = flags,
		underlay = memory_underlay_create(phys, size, backend),
	}
}

ALLOC_INITIAL_CAPACITY :: 8

PCIAddress :: bit_field u64 {
	segment:  u16 | 16,
	bus:      u8  | 8,
	device:   u8  | 8,
	function: u8  | 8,
}
CpuState :: struct #align (16) {
	self:           ^CpuState,
	kernelStackTop: u64,
	userSyscallRsp: u64,
	runState:       ^SavedState,
	syscallFrame:   ^SavedState,
	apicId:         u32,
	index:          u32,
	rrCurrent:      ^Execution,
	rrHead, rrTail: ^Execution,
	rrLock:         spinlock.Spinlock,
	sleeping:       bool,
}
#assert(offset_of(CpuState, kernelStackTop) == 8)
#assert(offset_of(CpuState, userSyscallRsp) == 16)
#assert(offset_of(CpuState, runState) == 24)
#assert(offset_of(CpuState, syscallFrame) == 32)
#assert(offset_of(CpuState, rrCurrent) == 48)

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


gKernelCtx: runtime.Context
gdts: []GDT
cpus: []CpuState
nextCPUSlot: u32 = 0
apReady: u32
kernelStacksBase: u64
sched_init :: proc(rsdp: ^acpi.Rsdp) {
	bspId := u32(ah.rdmsr_asm(0x802))
	apCount := acpi.collect_ap_ids(rsdp, bspId, nil)
	totalCores := int(apCount) + 1

	aErr: runtime.Allocator_Error
	gdts, aErr = make([]GDT, totalCores)
	print.kensure(aErr == nil, "OOM sched_init: gdts")

	pmm.gdtRegionBase = u64(uintptr(raw_data(gdts)))
	pmm.gdtRegionSize = u64(len(gdts)) * size_of(GDT)

	gdts[0] = gdtBeforeSched
	gdt_tss_fill(&gdts[0])

	ah.lgdt_asm(&gdts[0].desc)
	ah.reload_segments_asm()
	TSS_SEL :: u16(GDTEntryNames.Tss1) << 3
	ah.load_tss_asm(TSS_SEL)

	cpus, aErr = make([]CpuState, totalCores)
	print.kensure(aErr == nil, "OOM sched_init: cpus")

	trampolineStacksBase = pmm.alloc_zeroed(u64(totalCores) * TRAMPOLINE_STACK_SIZE)
	print.kensure(trampolineStacksBase != 0, "sched_init: trampoline stack allocation failed")
	pmm.trampolineRegionBase = trampolineStacksBase
	pmm.trampolineRegionSize = u64(totalCores) * TRAMPOLINE_STACK_SIZE

	kernelStacksStride := u64(KERNEL_STACK_PER_CPU_SIZE + shared.PAGE_SIZE)
	kernelStacksBase = pmm.alloc_zeroed(u64(totalCores) * kernelStacksStride)
	print.kensure(kernelStacksBase != 0, "sched_init: kernel stack allocation failed")
	pmm.kernelStacksRegionBase = kernelStacksBase
	pmm.kernelStacksRegionStride = kernelStacksStride
	pmm.kernelStacksRegionCount = u64(totalCores)

	cpu_init(cpus, 0, bspId, &gdts[0].tss.rsp[0], kernelStacksBase, &gdts[0].tss.ist[0])

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
		stride := u64(KERNEL_STACK_PER_CPU_SIZE + shared.PAGE_SIZE)
		cpu_init(
			cpus,
			cpuIndex,
			apId,
			&gdts[cpuIndex].tss.rsp[0],
			kernelStacksBase + u64(cpuIndex) * stride,
			&gdts[cpuIndex].tss.ist[0],
		)
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

	cpuid_enable_pcid()

	ah.gs_write_base(u64(uintptr(cpu)))
	lapic_enable_percpu()
	print.serial_writeln("lapic: x2apic enabled (ap)")
	intrinsics.atomic_store(&apReady, 1)

	cpu_syscall_init()
	cpu_idle_loop()
}

map_cpu_stack :: proc(base: u64) -> u64 {
	end := base + KERNEL_STACK_PER_CPU_SIZE + shared.PAGE_SIZE

	pmm.map_page(pmm.kernelPML4, base, base, ._4KB, {})
	for p := base + shared.PAGE_SIZE; p < end; p += shared.PAGE_SIZE {
		pmm.map_page(pmm.kernelPML4, p, p, ._4KB, {.NX, .Present, .Write})
	}

	assert((end & 0xF) == 0)
	return end
}

cpu_init :: proc(
	cpus: []CpuState,
	idx: u32,
	apicId: u32,
	tssRSP0: ^u64,
	stackBase: u64,
	tssIST0: ^u64,
) {
	cpu := &cpus[idx]
	cpu.self = cpu
	cpu.apicId = apicId
	cpu.index = idx

	top := map_cpu_stack(stackBase)
	cpu.kernelStackTop = top
	tssRSP0^ = top
	tssIST0^ = top
}

KERNELGSBASE :: u32(0xC0000102); IA32_GS_BASE :: u32(0xC0000101)
cpu_syscall_init :: proc() {
	IA32_EFER :: u32(0xC0000080); IA32_STAR :: u32(0xC0000081)
	IA32_LSTAR :: u32(0xC0000082); IA32_FMASK :: u32(0xC0000084)
	EFER_SCE :: u64(1 << 0)
	ah.wrmsr_asm(IA32_EFER, ah.rdmsr_asm(IA32_EFER) | EFER_SCE)
	ah.wrmsr_asm(IA32_STAR, (u64(ah.USER_CS32) << 48) | (u64(ah.KERNEL_CS) << 32))
	entry := cpuMeltdownVulnerable ? ah.syscall_entry_meltdown_safe : ah.syscall_entry
	ah.wrmsr_asm(IA32_LSTAR, u64(uintptr(rawptr(entry))))
	ah.wrmsr_asm(IA32_FMASK, u64(0x200))
	ah.wrmsr_asm(KERNELGSBASE, ah.rdmsr_asm(IA32_GS_BASE))
}
saved_state_fresh :: proc(entryRip, entryRsp: u64) -> SavedState {
	assert(entryRsp % 16 == 8, "saved_state_fresh: unaligned entry stack")
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
