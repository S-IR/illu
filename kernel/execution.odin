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
Execution :: struct {
	state:  SavedState,
	domain: ^ProtectionDomain,
	next:   ^Execution,
}

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_read_cpustate :: proc() -> ^CpuState ---
		run_domain :: proc(state: ^SavedState) ---
		run_abort :: proc(resumeRsp: u64) ---
		cpu_idle_loop :: proc() -> ! ---
		fxsave_asm :: proc(area: ^[512]u8) ---
	}
}

execution_run :: proc "contextless" (domain: ^ProtectionDomain, state: ^SavedState) {

	ah.write_cr3(domain.pml4)
	lapic_set_deadline(tscTicksPerMs * SLICE_MS)
	run_domain(state)
}
execution_enqueue :: proc "contextless" (e: ^Execution, cpu: ^CpuState) {

	{
		spinlock.lock(&cpu.rrLock)
		defer spinlock.unlock(&cpu.rrLock)

		e.next = nil
		if cpu.rrTail != nil {
			cpu.rrTail.next = e
		} else {
			cpu.rrHead = e
		}
		cpu.rrTail = e

	}
	if cpu.sleeping do send_ipi(cpu.apicId, VECTOR_APIC_IPI)


}
execution_dequeue :: proc "contextless" (cpu: ^CpuState) -> (e: ^Execution) {
	spinlock.lock(&cpu.rrLock)
	defer spinlock.unlock(&cpu.rrLock)

	e = cpu.rrHead
	if e == nil do return nil

	cpu.rrHead = e.next
	if cpu.rrHead == nil do cpu.rrTail = nil

	e.next = nil
	return e

}

execution_steal :: proc "contextless" (thief: ^CpuState) -> ^Execution {
	for i in 0 ..< len(cpus) {
		victim := &cpus[i]
		if victim.index == thief.index do continue
		if e := execution_dequeue(victim); e != nil do return e
	}
	return nil
}

rrCpuNext: uint = 0
@(export)
run_next_execution :: proc "c" () -> bool {
	// context = runtime.default_context()
	cpu := gs_read_cpustate()
	print.serial_write("hello i am here")
	print.kassert(cpu != nil, "rn: cpu nil")
	print.kassert(cpu.self == cpu, "rn: cpu self corrupt")

	print.serial_write("hello i am here 2")

	if cpu.rrCurrent == nil {
		exec := execution_dequeue(cpu)
		if exec == nil do return false
		cpu.rrCurrent = exec
	}

	exec := cpu.rrCurrent
	print.kassert(exec != nil, "rn: exec nil")
	print.kassert(exec.domain != nil, "rn: domain nil")
	print.kassert(exec.domain.pml4 != 0, "rn: pml4 zero")
	print.kassert(exec.state.rip != 0, "rn: rip zero")
	print.kassert(exec.state.rsp != 0, "rn: rsp zero")
	print.kassert(exec.state.cs == 0x2B, "rn: bad cs")
	print.kassert(exec.state.ss == 0x23, "rn: bad ss")
	print.kassert(exec.state.rsp % 16 == 0, "rn: rsp unaligned")
	print.serial_write("hello i am here 3")


	execution_run(exec.domain, &exec.state)

	print.serial_write("hello i am here 4")

	return true
}
@(export)
cpu_prepare_sleep :: proc "c" () -> bool {
	cpu := gs_read_cpustate()
	spinlock.lock(&cpu.rrLock)
	defer spinlock.unlock(&cpu.rrLock)

	if cpu.rrHead != nil do return false
	cpu.sleeping = true
	return true

}
@(export)
cpu_clear_sleeping :: proc "c" () {
	cpu := gs_read_cpustate()
	cpu.sleeping = false
}
domain_destroy :: proc(domain: ^ProtectionDomain) {
	for a in domain.allocs {
		pmm.pfree(a.phys, a.pages * shared.PAGE_SIZE)
	}
	delete(domain.allocs)

	pmm.pfree(domain.pml4, shared.PAGE_SIZE)
	free(domain)
}

exec_exit_current :: proc "c" () {
	context = runtime.default_context()
	cpu := gs_read_cpustate()
	exec := cpu.rrCurrent
	print.kassert(exec != nil, "exec_exit_current: no execution running on this CPU")
	if exec == nil do return

	cpu.rrCurrent = nil
	domain_destroy(exec.domain)
	free(exec)
	run_abort(cpu.schedulerResumeRsp)
}
