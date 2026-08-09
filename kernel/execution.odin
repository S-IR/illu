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

// Syscalls arrive with the domain CR3 still loaded.  Keep the transition in
// one kernel-side entry point so the assembly boundary does not need to know
// about scheduler/domain state.
@(export)
syscall_enter_kernel :: proc "c" () -> u64 {
	cpu := gs_read_cpustate()
	print.kassert(cpu != nil, "syscall_enter_kernel: cpu nil")
	exec := cpu.rrCurrent
	print.kassert(exec != nil, "syscall_enter_kernel: no execution")
	print.kassert(exec.domain != nil, "syscall_enter_kernel: no domain")

	domainPML4 := exec.domain.pml4
	ah.write_cr3(pmm.kernelPML4)
	return domainPML4
}

@(export)
syscall_restore_domain :: proc "c" (domainPML4: u64) {
	print.kassert(domainPML4 != 0, "syscall_restore_domain: zero pml4")
	ah.write_cr3(domainPML4)
}

restore_current_domain_cr3 :: proc "contextless" () {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil do return
	if cpu.rrCurrent.domain == nil do return
	ah.write_cr3(cpu.rrCurrent.domain.pml4)
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
	print.kassert(cpu != nil, "rn: cpu nil")
	print.kassert(cpu.self == cpu, "rn: cpu self corrupt")


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
	execution_run(exec.domain, &exec.state)


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
	// Syscalls enter the kernel without changing CR3.  The domain maps its
	// image with its ELF permissions, so allocator cleanup must use the kernel
	// identity map before writing buddy-list metadata into freed pages.
	ah.write_cr3(pmm.kernelPML4)

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
