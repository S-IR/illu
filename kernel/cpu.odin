package kernel

import ah "../asm_helpers"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/userschedule"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:slice"
import "pmm"
import "print"

KERNEL_STACK_PER_CPU_SIZE :: 16 * mem.Kilobyte
IST_STACK_SIZE :: 8 * mem.Kilobyte
#assert(KERNEL_STACK_PER_CPU_SIZE % shared.PAGE_SIZE == 0)
#assert(IST_STACK_SIZE % shared.PAGE_SIZE == 0)

IA32_TSC_AUX :: u32(0xC0000103)
IA32_GS_BASE :: u32(0xC0000101)
IA32_KERNEL_GS_BASE :: u32(0xC0000102)
X2APIC_MSR_APIC_ID :: u32(0x802)

CpuState :: struct #align (64) {
	self:             ^CpuState,
	kernelStackTop:   u64,
	userSyscallRsp:   u64,
	userCr3:          u64,
	syscallScratch:   u64,
	lock:             spinlock.Spinlock,
	currentGrant:     CpuGrant,
	grants:           [dynamic]CpuGrant,
	floorVirtualTime: u64,
	tlbEpoch:         u64,
}
#assert(offset_of(CpuState, self) == 0)
#assert(offset_of(CpuState, kernelStackTop) == 8)
#assert(offset_of(CpuState, userSyscallRsp) == 16)
#assert(offset_of(CpuState, userCr3) == 24)
#assert(offset_of(CpuState, syscallScratch) == 32)
#assert(align_of(CpuState) == 64)
#assert(size_of(CpuState) % 64 == 0)

gKernelCtx: runtime.Context
gdts: []GDT
cpus: []CpuState
CpuInfos: ^userschedule.CpuInfoPage
cpuInfosPhys: u64
apReady: u32

FxArea :: struct #align (16) {
	bytes: [512]u8,
}

@(export, link_name = "kernel_clean_fx")
cleanFx: FxArea

cpus_init :: proc(apicIds: []u32) {
	print.kensure(cpuid_has_rdtscp(), "cpus_init: rdtscp unsupported")
	print.kensure(cpuid_has_fsgsbase(), "cpus_init: fsgsbase unsupported")
	(^u16)(&cleanFx.bytes[0])^ = userschedule.FX_FCW_DEFAULT
	(^u32)(&cleanFx.bytes[userschedule.FX_MXCSR_OFFSET])^ = userschedule.MXCSR_DEFAULT

	bspId := u32(ah.rdmsr_asm(X2APIC_MSR_APIC_ID))
	bspIdx, bspFound := slice.linear_search(apicIds, bspId)
	print.kensure(bspFound, "cpus_init: bsp apic id missing from firmware list")
	slice.swap(apicIds, 0, bspIdx)
	cpuCount := len(apicIds)

	gdtsBytes := pmm.addr_round_up_to_page(u64(cpuCount) * size_of(GDT))
	gdts = ([^]GDT)(uintptr(pmm.entry_region_alloc(gdtsBytes, guard = false)))[:cpuCount]
	cpusBytes := pmm.addr_round_up_to_page(u64(cpuCount) * size_of(CpuState))
	cpus = ([^]CpuState)(uintptr(pmm.entry_region_alloc(cpusBytes, guard = false)))[:cpuCount]

	cpuInfosBytes := pmm.addr_round_up_to_page(cpu_infos_bytes(cpuCount))
	cpuInfosPhys = pmm.alloc_zeroed(cpuInfosBytes)
	print.kensure(cpuInfosPhys != 0, "cpus_init: cpu info alloc failed")
	CpuInfos = (^userschedule.CpuInfoPage)(pmm.phys_to_ptr(cpuInfosPhys))
	CpuInfos.cpuCount = u32(cpuCount)
	print.kensure(tscTicksPerMs != 0, "cpus_init: lapic_init must calibrate the tsc first")
	CpuInfos.tscTicksPerMs = tscTicksPerMs

	for &cpu, idx in cpus {
		cpu_init(&cpu, apicIds[idx])
	}

	cr3NoFlushBit = PCID_NOFLUSH_BIT if cpuHasPCID else 0
	kernelCr3Value = pmm.kernelPML4 | (u64(KERNEL_PCID) | cr3NoFlushBit if cpuHasPCID else 0)

	cpu_setup(&cpus[0])
	for &cpu in cpus[1:] {
		install_trampoline(
			rawptr(uintptr(pmm.TRAMPOLINE_PHYS)),
			pmm.kernelPML4,
			cpu.kernelStackTop,
			u64(uintptr(rawptr(ap_init))),
			u64(uintptr(&cpu)),
		)
		intrinsics.atomic_store(&apReady, 0)
		send_init_sipi(cpu_info(&cpu).apicId, pmm.TRAMPOLINE_PHYS)
		for intrinsics.atomic_load(&apReady) == 0 do intrinsics.cpu_relax()
	}
}

cpu_init :: proc(cpu: ^CpuState, apicId: u32) {
	idx := cpu_index(cpu)
	cpu.self = cpu
	cpu.kernelStackTop = pmm.entry_region_alloc(KERNEL_STACK_PER_CPU_SIZE, guard = true) + KERNEL_STACK_PER_CPU_SIZE
	cpu_info(cpu).apicId = apicId

	aErr: runtime.Allocator_Error
	cpu.grants, aErr = make([dynamic]CpuGrant, 0, CPU_GRANT_STARTING_CAPACITY)
	print.kensure(aErr == nil, "OOM cpu_init: grants")

	gdt := &gdts[idx]
	gdt_tss_fill(gdt)
	gdt.tss.rsp[0] = cpu.kernelStackTop
	gdt.tss.ist[0] = pmm.entry_region_alloc(IST_STACK_SIZE, guard = true) + IST_STACK_SIZE
}

cpu_setup :: proc(cpu: ^CpuState) {
	ah.lidt_asm(&GIDTDescriptor)
	gdt_tss_load(&gdts[cpu_index(cpu)])
	cpuid_enable_pcid()
	cpuid_enable_fsgsbase()
	cpu_enable_kernel_protections()
	cpu_enable_ssbd()
	ah.gs_write_base(u64(uintptr(cpu)))
	ah.wrmsr_asm(IA32_TSC_AUX, u64(cpu_index(cpu)))
	cpu_syscall_init()
	lapic_enable_percpu()
	info := cpu_info(cpu)
	idle_states_init(info)
	intrinsics.atomic_store(&info.online, true)
}

ap_init :: proc "c" (cpu: ^CpuState) -> ! {
	context = gKernelCtx
	cpu_setup(cpu)
	intrinsics.atomic_store(&apReady, 1)
	grant_loop()
}

cpu_index :: proc "contextless" (cpu: ^CpuState) -> int {
	return int((uintptr(cpu) - uintptr(raw_data(cpus))) / size_of(CpuState))
}

cpu_info :: proc "contextless" (cpu: ^CpuState) -> ^userschedule.CpuInfo {
	return &userschedule.cpu_infos(CpuInfos)[cpu_index(cpu)]
}

idle_states_init :: proc(info: ^userschedule.CpuInfo) {
	MONITOR_FEATURE_BIT :: 3
	MWAIT_EXTENSIONS_BIT :: 0

	features: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &features)
	if (features.ecx >> MONITOR_FEATURE_BIT) & 1 == 0 do return

	maxLeaf: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &maxLeaf)
	if maxLeaf.eax < u32(ah.CPUIDLeaf.MONITOR_MWAIT) do return

	mwait: ah.CPUIDResult
	ah.cpuid_asm(.MONITOR_MWAIT, 0, &mwait)
	if (mwait.ecx >> MWAIT_EXTENSIONS_BIT) & 1 == 0 do return

	for cState in u32(1) ..= userschedule.MAX_IDLE_STATES {
		substates := (mwait.edx >> (cState * 4)) & 0xF
		if substates == 0 do continue
		assert(info.idleCount < userschedule.MAX_IDLE_STATES)
		info.mwaitHints[info.idleCount] = (cState - 1) << 4
		info.idleCount += 1
	}
}

cpu_syscall_init :: proc() {
	IA32_EFER :: u32(0xC0000080)
	IA32_STAR :: u32(0xC0000081)
	IA32_LSTAR :: u32(0xC0000082)
	IA32_FMASK :: u32(0xC0000084)
	EFER_SCE :: u64(1 << 0)
	RFLAGS_KERNEL_CLEARED :: u64(0x47700)
	ah.wrmsr_asm(IA32_EFER, ah.rdmsr_asm(IA32_EFER) | EFER_SCE)
	ah.wrmsr_asm(IA32_STAR, (u64(ah.USER_CS32) << 48) | (u64(ah.KERNEL_CS) << 32))
	entry := cpuMeltdownVulnerable ? ah.syscall_entry_meltdown_safe : ah.syscall_entry
	ah.wrmsr_asm(IA32_LSTAR, u64(uintptr(rawptr(entry))))
	ah.wrmsr_asm(IA32_FMASK, RFLAGS_KERNEL_CLEARED)
	ah.wrmsr_asm(IA32_KERNEL_GS_BASE, ah.rdmsr_asm(IA32_GS_BASE))
}

cpu_infos_bytes :: proc "contextless" (count: int) -> u64 {
	return u64(size_of(userschedule.CpuInfoPage) + size_of(userschedule.CpuInfo) * count)
}

cpu_info_map :: proc(pml4: u64) {
	assert(CpuInfos != nil)
	assert(CpuInfos.cpuCount > 0)
	bytes := cpu_infos_bytes(int(CpuInfos.cpuCount))
	for offset := u64(0); offset < bytes; offset += shared.PAGE_SIZE {
		pmm.map_page(
			pml4,
			cpuInfosPhys + offset,
			userschedule.CPU_INFO_ADDR + offset,
			._4KB,
			{.Present, .User, .NX},
		)
	}
}
