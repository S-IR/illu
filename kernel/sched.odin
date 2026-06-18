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
	rsp:       u64,
	process:   ^Process,
	state:     ThreadState,
	next:      ^Thread,
	id:        u64,
	stackTop:  u64,
	stackSize: u64,
}
ThreadState :: enum u8 {
	Ready,
	Running,
	Blocked,
}

IdleHint :: enum u8 {
	Shallow = 0x00, // C1
	C1E     = 0x10, // C1E
	Deep    = 0x40, // C6 – deepest documented state
}
DEFAULT_IDLE_HINT :: IdleHint.Deep

CpuState :: struct {
	self:             ^CpuState, // 0
	kernelRSP:        u64, // 8
	userRSP:          u64, // 16
	tssRSP0:          ^u64, // 24
	current:          ^Thread, // 32
	pendingFree:      ^Thread, // 40
	kernelSyscallRSP: u64, // 48
	id:               u32, // 56
	idleHint:         IdleHint, // 60
	_pad:             [3]u8, // 61-63
	idleStackTop:     u64, // 64
	runQueue:         RunQueue, // 72
}

#assert(offset_of(CpuState, kernelRSP) == 8)
#assert(offset_of(CpuState, userRSP) == 16)
#assert(offset_of(CpuState, tssRSP0) == 24)
#assert(offset_of(CpuState, kernelSyscallRSP) == 48)
#assert(offset_of(CpuState, idleHint) == 60)
#assert(offset_of(Thread, rsp) == 0)
#assert(offset_of(Thread, stackTop) == 40)

RUN_QUEUE_CAP :: 256

RunQueue :: struct {
	buf:  [RUN_QUEUE_CAP]^Thread,
	head: u64,
	tail: u64,
}

cpu0: CpuState
nextID: u64 = 1
nextCPU: u32
gKernelCtx: runtime.Context


sched_init :: proc(rsdp: ^acpi.Rsdp) {
	print.kensure(cpuid_has_sse3(), "CPU does not support SSE3 (MONITOR/MWAIT)")
	gKernelCtx = context
	cpu0.tssRSP0 = &gdtTss.rsp[0]


	cpu_init(&cpu0)
	smp_start(rsdp)

}
gAPReady: u32

smp_start :: proc(rsdp: ^acpi.Rsdp) {
	X2APIC_MSR_ID :: 0x802
	bspId := u8(ah.rdmsr_asm(X2APIC_MSR_ID) & 0xFF)

	apCount := acpi.collect_ap_ids(rsdp, bspId, nil)
	apIds, allocErr := make([]u8, apCount, context.temp_allocator)
	print.kensure(allocErr == nil, "OOM smp_start")
	acpi.collect_ap_ids(rsdp, bspId, apIds)


	cr3 := ah.read_cr3()
	for apId in apIds {
		tempStack := make([]u8, IDLE_STACK_SIZE)
		print.kassert(raw_data(tempStack) != nil, "smp_start: temp stack alloc failed")
		tempStackTop := u64(uintptr(raw_data(tempStack))) + IDLE_STACK_SIZE

		intrinsics.atomic_store(&gAPReady, u32(0))
		install_trampoline(
			rawptr(uintptr(pmm.trampolinePhys)),
			cr3,
			tempStackTop,
			u64(uintptr(rawptr(ap_init))),
		)
		send_init_sipi(apId, pmm.trampolinePhys)
		for intrinsics.atomic_load(&gAPReady) == 0 {
			intrinsics.cpu_relax()
		}
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
	cpu.id = intrinsics.atomic_add(&nextCPU, 1)
	cpu.idleHint = DEFAULT_IDLE_HINT
	cpu.current = nil

	idleStack, allocErr := make([]u8, IDLE_STACK_SIZE)
	print.kensure(allocErr == {} && raw_data(idleStack) != nil, "OOM cpu_init")
	cpu.idleStackTop = u64(uintptr(raw_data(idleStack))) + IDLE_STACK_SIZE

	cpu.tssRSP0^ = cpu.idleStackTop
	ah.gs_write_base(u64(uintptr(cpu)))
	ah.cpu_syscall_init()
	idt_set_entry(VECTOR_APIC_TIMER, u64(uintptr(rawptr(timer_tick))))


}
ap_init :: proc "c" () {
	context = gKernelCtx
	intrinsics.atomic_store(&gAPReady, u32(1))
	ah.lgdt_asm(&GDTDescriptor)
	ah.lidt_asm(&GIDTDescriptor)

	cpu, allocErr := new(CpuState)
	print.kensure(allocErr == nil, "OOM ap_init")

	apTss: ^TSS
	apTss, allocErr = new(TSS)
	print.kensure(allocErr == nil, "OOM ap_init")
	ah.load_tss_asm(u16(GDTEntryNames.Tss1) << 3)
	cpu.tssRSP0 = &apTss.rsp[0]

	cpu_init(cpu)
	lapic_set_deadline(tscTicksPerMs * SLICE_MS)
	ah.sti_asm()
	thread_start_idle_loop()
}
timer_tick :: proc() {
	lapic_send_eoi()
	lapic_set_deadline(tscTicksPerMs * SLICE_MS)
	thread_switch_away()
}
