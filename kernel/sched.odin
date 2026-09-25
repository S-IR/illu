package kernel
import ah "../asm_helpers"
import "../lib/acpi"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"
KERNEL_STACK_PER_CPU_SIZE :: 16 * mem.Kilobyte
#assert(KERNEL_STACK_PER_CPU_SIZE % 16 == 0)

IA32_TSC_AUX :: u32(0xC0000103)


IdleLevel :: distinct u8
when ODIN_ARCH == .amd64 {
	MAX_IDLE_STATES :: 7

	IdleState :: struct {
		level:     IdleLevel,
		mwaitHint: u32,
	}
	CpuIdleInfo :: struct {
		states: [dynamic; MAX_IDLE_STATES]IdleState,
	}
} else {
	IdleState :: struct {
		level:       IdleLevel,
		psciStateId: u32,
	}

	CpuIdleInfo :: struct {
		states: [dynamic]IdleState,
	}
}


CpuState :: struct #align (16) {
	self:              ^CpuState,
	kernelStackTop:    u64,
	userSyscallRsp:    u64,
	apicId:            u32,
	index:             u32,
	userFx:            [512]u8,
	currentGrant:      CpuGrant,
	grants:            [dynamic]CpuGrant,
	grantStartTsc:     u64,
	floorVirtualTime:  u64,
	grantLock:         spinlock.Spinlock,
	wakeEvent:         u32,
	idleInfo:          CpuIdleInfo,
	selectedIdleLevel: IdleLevel,
	info:              ^syscalls.CpuInfo,
}
#assert(offset_of(CpuState, self) == 0)
#assert(offset_of(CpuState, kernelStackTop) == 8)
#assert(offset_of(CpuState, userSyscallRsp) == 16)
#assert(offset_of(CpuState, apicId) == 24)
#assert(offset_of(CpuState, userFx) == 32)
#assert(align_of(CpuState) == 16)


gKernelCtx: runtime.Context
gdts: []GDT
cpus: []CpuState
nextCPUSlot: u32 = 0
apReady: u32
kernelStacksBase: u64
sched_init :: proc(rsdp: ^acpi.Rsdp) {
	print.kensure(cpuid_has_rdtscp(), "sched_init: rdtscp unsupported")

	(^u16)(&cleanFx.bytes[0])^ = FX_FCW_DEFAULT
	(^u32)(&cleanFx.bytes[FX_MXCSR_OFFSET])^ = MXCSR_DEFAULT

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

	CpuInfos = (^syscalls.CpuInfoPage)(uintptr(pmm.alloc_zeroed(cpu_infos_bytes(totalCores))))
	print.kensure(CpuInfos != nil, "sched_init: cpu info alloc failed")
	CpuInfos.cpuCount = u32(totalCores)

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
	ah.wrmsr_asm(IA32_TSC_AUX, u64(cpus[0].index))
	intrinsics.atomic_store(&cpus[0].info.online, true)
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
	ah.wrmsr_asm(IA32_TSC_AUX, u64(cpu.index))
	intrinsics.atomic_store(&cpu.info.online, true)
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
	cpu.info = &syscalls.cpu_infos(CpuInfos)[idx]

	top := map_cpu_stack(stackBase)
	cpu.kernelStackTop = top
	tssRSP0^ = top
	tssIST0^ = top

	assert(uintptr(&cpu.userFx) % 16 == 0)
	aErr: runtime.Allocator_Error
	cpu.grants, aErr = make([dynamic]CpuGrant, 0, CPU_GRANT_STARTING_CAPACITY)
	print.kensure(aErr == nil, "OOM cpu_init: grants")

	when ODIN_ARCH == .amd64 do idle_info_init_x64(cpu)

}

when ODIN_ARCH == .amd64 {
	idle_info_init_x64 :: proc(cpu: ^CpuState) {
		maxLeaf: ah.CPUIDResult
		ah.cpuid_asm(.VENDOR_STRING, 0, &maxLeaf)

		if maxLeaf.eax < u32(ah.CPUIDLeaf.MONITOR_MWAIT) do return

		r: ah.CPUIDResult
		ah.cpuid_asm(.MONITOR_MWAIT, 0, &r)

		for c in u32(1) ..< 8 {
			substateCount := (r.edx >> (c * 4)) & 0xF
			if substateCount == 0 do continue

			state := IdleState {
				level     = IdleLevel(len(cpu.idleInfo.states)),
				mwaitHint = c,
			}

			append(&cpu.idleInfo.states, state)
		}
	}
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


FX_FCW_DEFAULT :: u16(0x037F)
MXCSR_DEFAULT :: u32(0x1F80)
MXCSR_SAFE_MASK :: u32(0xFFBF)
FX_MXCSR_OFFSET :: 24

FxArea :: struct #align (16) {
	bytes: [512]byte,
}

@(export, link_name = "kernel_clean_fx")
cleanFx: FxArea


CpuInfos: ^syscalls.CpuInfoPage

cpu_infos_bytes :: proc(count: int) -> u64 {
	return u64(size_of(syscalls.CpuInfoPage) + size_of(syscalls.CpuInfo) * count)
}

cpu_info_map :: proc(pml4: u64) {
	assert(CpuInfos != nil)
	assert(CpuInfos.cpuCount > 0)
	for offset := u64(0);
	    offset < cpu_infos_bytes(int(CpuInfos.cpuCount));
	    offset += shared.PAGE_SIZE {
		pmm.map_page(
			pml4,
			u64(uintptr(CpuInfos)) + offset,
			syscalls.CPU_INFO_ADDR + offset,
			._4KB,
			{.Present, .User, .NX},
		)
	}
}
