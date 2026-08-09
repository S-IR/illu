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
	print.kassert(domain != nil, "execution_run: nil domain")
	print.kassert(intrinsics.atomic_load(&domain.executionCount) > 0, "execution_run: domain has no executions")
	ah.write_cr3(domain.pml4)
	lapic_set_deadline(tscTicksPerMs * SLICE_MS)
	run_domain(state)
}

// execution_create creates one runnable execution in a kernel-owned domain.
// The execution count is used to prevent domain destruction while it runs.
execution_create :: proc(domain: ^ProtectionDomain, state: SavedState) -> ^Execution {
	print.kassert(domain != nil, "execution_create: nil domain")
	if domain == nil do return nil

	spinlock.lock(&domain.executionLock)
	defer spinlock.unlock(&domain.executionLock)
	execMem, err := mem.alloc(size_of(Execution), 16)
	print.kensure(err == nil, "execution_create: allocation failure")
	if err != nil do return nil

	exec := cast(^Execution)execMem
	exec^ = Execution{state = state, domain = domain}
	intrinsics.atomic_add(&domain.executionCount, 1)
	return exec
}

// execution_release removes exactly one execution from the domain and frees
// the execution object. The final execution also owns the domain teardown.
execution_release :: proc(exec: ^Execution) {
	print.kassert(exec != nil, "execution_release: nil execution")
	if exec == nil do return
	defer free(exec)

	domain := exec.domain
	print.kassert(domain != nil, "execution_release: nil domain")
	if domain == nil do return

	// Use CAS rather than an unconditional subtract: a stale/double release
	// must not wrap the count and resurrect the domain's paging lifetime.
	destroy_domain := false
	{
		spinlock.lock(&domain.executionLock)
		defer spinlock.unlock(&domain.executionLock)

		for {
			count := intrinsics.atomic_load(&domain.executionCount)
			print.kassert(count > 0, "execution_release: execution count underflow")
			if count == 0 do return
			if intrinsics.atomic_compare_exchange_strong(
				&domain.executionCount,
				count,
				count - 1,
			) == count {
				destroy_domain = count == 1
				break
			}
		}
	}
	if destroy_domain do domain_destroy(domain)
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
	print.kassert(domain != nil, "domain_destroy: nil domain")
	if domain == nil do return
	count := intrinsics.atomic_load(&domain.executionCount)
	print.kassert(count == 0, "domain_destroy: executions still attached")
	if count != 0 do return
	defer free(domain)
	defer delete(domain.allocs)

	// Syscalls enter the kernel without changing CR3.  The domain maps its
	// image with its ELF permissions, so allocator cleanup must use the kernel
	// identity map before writing buddy-list metadata into freed pages.
	ah.write_cr3(pmm.kernelPML4)

	for a in domain.allocs {
		pmm.pfree(a.phys, a.pages * shared.PAGE_SIZE)
	}
	print.kassert(domain.pml4 != 0, "domain_destroy: paging already destroyed")
	pmm.pml4_destroy(domain.pml4)
	domain.pml4 = 0
}

exec_exit_current :: proc "c" () {
	context = runtime.default_context()
	cpu := gs_read_cpustate()
	exec := cpu.rrCurrent
	print.kassert(exec != nil, "exec_exit_current: no execution running on this CPU")
	if exec == nil do return

	cpu.rrCurrent = nil
	execution_release(exec)
	run_abort(cpu.schedulerResumeRsp)
}
