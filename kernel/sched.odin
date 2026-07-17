package kernel
import ah "../asm_helpers"
import "../lib/acpi"
import "../lib/shared"
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"
SLICE_MS: u64 : 20
SLICE_WARN_MS: u64 : SLICE_MS - 2
KERNEL_STACK_PER_CPU_SIZE :: 16 * mem.Kilobyte

//allignment requirement
#assert(KERNEL_STACK_PER_CPU_SIZE % 16 == 0)
Process :: struct {
	pml4s:      [dynamic]u64,
	activePml4: u64,
	allocs:     [dynamic]Alloc,
	pid:        u64,
}

Alloc :: struct {
	phys:  u64,
	pages: u64,
}

Thread :: struct {
	rsp:                u64,
	process:            ^Process,
	state:              ThreadState,
	next:               ^Thread,
	id:                 u64,
	stackTop:           u64,
	stackSize:          u64,
	preemptRip:         u64,
	savedRip, savedRsp: u64,
	warned:             bool,
}
ThreadState :: enum u8 {
	Ready,
	Running,
	Blocked,
}

IdleHint :: enum u8 {
	Shallow = 0x00, // C1
	C1E     = 0x10, // C1E
	Deep    = 0x40,
}
DEFAULT_IDLE_HINT :: IdleHint.Deep

CpuState :: struct {
	self:               ^CpuState,
	kernelRSP, userRSP: u64,
	tssRSP0:            ^u64,
	current:            ^Thread,
	idleHint:           IdleHint,
	_pad:               [3]u8,
	runQueue:           RunQueue,
}

#assert(offset_of(CpuState, kernelRSP) == 8)
#assert(offset_of(CpuState, userRSP) == 16)
#assert(offset_of(CpuState, tssRSP0) == 24)
#assert(offset_of(CpuState, current) == 32)
#assert(offset_of(CpuState, idleHint) == 40)
#assert(offset_of(Thread, rsp) == 0)
#assert(offset_of(Thread, stackTop) == 40)

RunQueue :: struct {
	head, tail: ^Thread,
}

cpu0: CpuState
nextID: u64 = 1
nextCPU: u32
gKernelCtx: runtime.Context

gdts: []GDT
sched_init :: proc(rsdp: ^acpi.Rsdp) {
	print.kensure(cpuid_has_sse3(), "CPU does not support SSE3 (MONITOR/MWAIT)")

	X2APIC_MSR_ID :: 0x802
	bspId := u8(ah.rdmsr_asm(X2APIC_MSR_ID) & 0xFF)
	apCount := acpi.collect_ap_ids(rsdp, bspId, nil)
	totalCores := int(apCount) + 1

	print.serial_write("AP count: ")
	print.serial_write_u64(u64(apCount))
	print.serial_writeln("")

	print.serial_write("Total cores: ")
	print.serial_write_u64(u64(totalCores))
	print.serial_writeln("")

	gdtsAlloc, allocErr := make([]GDT, totalCores)
	print.kensure(allocErr == nil, "OOM sched_init: gdts")
	gdts = gdtsAlloc

	gdt_tss_init(&gdts[0])
	cpu0.tssRSP0 = &gdts[0].tss.rsp[0]

	cpu_init(&cpu0)
	smp_start(rsdp)
}

smp_start :: proc(rsdp: ^acpi.Rsdp) {
	X2APIC_MSR_ID :: 0x802
	bspId := u8(ah.rdmsr_asm(X2APIC_MSR_ID) & 0xFF)

	apCount := acpi.collect_ap_ids(rsdp, bspId, nil)
	apIds, allocErr := make([]u8, apCount, context.allocator)
	print.kensure(allocErr == nil, "OOM smp_start")
	acpi.collect_ap_ids(rsdp, bspId, apIds)

	cr3 := ah.read_cr3()
	for apId in apIds {
		kernelStack, aErr := make([]byte, KERNEL_STACK_PER_CPU_SIZE)
		print.kensure(aErr == nil, "smp_start: temp stack alloc failed")
		kernelStackTop := u64(uintptr(raw_data(kernelStack))) + KERNEL_STACK_PER_CPU_SIZE

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
sched_start :: proc() {
	cpu := gs_read_cpustate()
	cpu.current = nil

	lapic_set_deadline(tscTicksPerMs * SLICE_MS)
	ah.sti_asm()
	thread_switch_away()
}
cpu_init :: proc(cpu: ^CpuState) {
	cpu.self = cpu

	cpu.idleHint = DEFAULT_IDLE_HINT

	kernelStack, aErr := make([]u8, KERNEL_STACK_PER_CPU_SIZE)
	print.kensure(aErr == nil, "cpu_init: allocation failure for kernel stack")
	cpu.kernelRSP = u64(uintptr(raw_data(kernelStack))) + KERNEL_STACK_PER_CPU_SIZE

	cpu.tssRSP0^ = cpu.kernelRSP
	ah.gs_write_base(u64(uintptr(cpu)))
	cpu_syscall_init()


}
cpu_syscall_init :: proc() {
	IA32_EFER :: u32(0xC0000080)
	IA32_STAR :: u32(0xC0000081)
	IA32_LSTAR :: u32(0xC0000082)
	IA32_FMASK :: u32(0xC0000084)
	KERNELGSBASE :: u32(0xC0000102)
	EFER_SCE :: u64(1 << 0)
	IA32_GS_BASE :: u32(0xC0000101)
	ah.wrmsr_asm(IA32_EFER, ah.rdmsr_asm(IA32_EFER) | EFER_SCE)
	ah.wrmsr_asm(IA32_STAR, (u64(ah.USER_CS32) << 48) | (u64(ah.KERNEL_CS) << 32))
	ah.wrmsr_asm(IA32_LSTAR, u64(uintptr(rawptr(ah.syscall_entry))))
	ah.wrmsr_asm(IA32_FMASK, u64(0x200))
	ah.wrmsr_asm(KERNELGSBASE, ah.rdmsr_asm(IA32_GS_BASE))
}

nextGdtSlot: u32 = 1
apReady: u32
ap_init :: proc "c" () {
	intrinsics.atomic_store(&apReady, 1)
	ah.wrmsr_asm(u32(0xC0000100), gBootTlsEnd)
	context = gKernelCtx
	ah.lidt_asm(&GIDTDescriptor)

	slot := intrinsics.atomic_add(&nextGdtSlot, 1) - 1
	gdt_tss_init(&gdts[slot])

	cpu, allocErr := new(CpuState)
	print.kensure(allocErr == nil, "OOM ap_init")
	cpu.tssRSP0 = &gdts[slot].tss.rsp[0]

	cpu_init(cpu)
	thread_start_idle_loop()
}
timer_tick :: proc(frame: ^InterruptFrame) {
	cpu := gs_read_cpustate()
	t := cpu.current


	if t != nil && !t.warned && t.preemptRip != 0 {
		t.warned = true
		t.savedRip = frame.rip
		t.savedRsp = frame.rsp

		frame.rip = t.preemptRip
		frame.rdi = t.savedRip
		frame.rsi = t.savedRsp

		lapic_set_deadline(tscTicksPerMs * SLICE_WARN_MS)
		return
	}

	lapic_set_deadline(tscTicksPerMs * SLICE_MS)
	if t != nil do t.warned = false
	thread_switch_away()
}
