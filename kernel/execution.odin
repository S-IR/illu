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
	schedulerState: ExecutionState,
	state:          SavedState,
	domain:         ^ProtectionDomain,
	next:           ^Execution,
}
#assert(offset_of(Execution, domain) == 704)

ExecutionState :: enum {
	Runnable,
	WaitingOnInterrupt,
}

TRAMPOLINE_STACK_SIZE :: 256
trampolineStacksBase: u64

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_read_cpustate :: proc() -> ^CpuState ---
		run_domain :: proc(state: ^SavedState, targetPml4: u64, trampolineTop: u64) ---
		run_abort :: proc() -> ! ---
		cpu_idle_loop :: proc() -> ! ---
		fxsave_asm :: proc(area: ^[512]u8) ---
	}
} else {
	@(thread_local)
	testCpu: ^CpuState

	gs_read_cpustate :: proc "contextless" () -> ^CpuState {return testCpu}
	run_domain :: proc "contextless" (state: ^SavedState, targetPml4: u64, trampolineTop: u64) {}
	run_abort :: proc "contextless" () -> ! {for {}}
	cpu_idle_loop :: proc "contextless" () -> ! {for {}}
	fxsave_asm :: proc "contextless" (area: ^[512]u8) {}
}

execution_run :: proc "contextless" (domain: ^ProtectionDomain, state: ^SavedState) {
	print.kassert(domain != nil, "execution_run: nil domain")
	print.kassert(
		intrinsics.atomic_load(&domain.executionCount) > 0,
		"execution_run: domain has no executions",
	)
	lapic_set_deadline(tscTicksPerMs * SLICE_MS)
	cpu := gs_read_cpustate()
	print.kassert(cpu != nil, "execution_run: no current cpu")
	top := trampolineStacksBase + u64(cpu.index + 1) * TRAMPOLINE_STACK_SIZE
	run_domain(state, domain.pml4, top)
}

execution_create :: proc(domain: ^ProtectionDomain, state: SavedState) -> ^Execution {
	print.kassert(domain != nil, "execution_create: nil domain")
	if domain == nil do return nil
	print.kassert(domain.pml4 != 0, "execution_create: domain has no PML4")
	print.kassert(state.rip != 0, "execution_create: zero entry RIP")
	print.kassert(state.rsp != 0, "execution_create: zero entry RSP")
	print.kassert(state.cs == 0x2B, "execution_create: bad code segment")
	print.kassert(state.ss == 0x23, "execution_create: bad stack segment")
	print.kassert(state.rsp % 16 == 8, "execution_create: unaligned entry stack")

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)
	if domain.killed do return nil

	execMem, err := mem.alloc(size_of(Execution), 16)
	print.kensure(err == nil, "execution_create: allocation failure")
	if err != nil do return nil

	exec := cast(^Execution)execMem
	exec^ = Execution {
		schedulerState = .Runnable,
		state          = state,
		domain         = domain,
	}
	intrinsics.atomic_add(&domain.executionCount, 1)
	append(&domain.executions, exec)
	return exec
}

execution_release :: proc(exec: ^Execution) {
	print.kassert(exec != nil, "execution_release: nil execution")
	if exec == nil do return
	defer free(exec)
	interrupt_release_execution(exec)

	domain := exec.domain
	print.kassert(domain != nil, "execution_release: nil domain")
	if domain == nil do return
	print.kassert(domain.pml4 != 0, "execution_release: domain PML4 already gone")

	spinlock.rw_write_lock(&domain.lock)
	count := intrinsics.atomic_load(&domain.executionCount)
	print.kassert(count > 0, "execution_release: execution count underflow")
	if count == 0 {
		spinlock.rw_write_unlock(&domain.lock)
		return
	}
	intrinsics.atomic_store(&domain.executionCount, count - 1)
	for e, i in domain.executions {
		if e == exec {
			unordered_remove(&domain.executions, i)
			break
		}
	}
	if count != 1 {
		spinlock.rw_write_unlock(&domain.lock)
		return
	}

	domain_reclaim_locked(domain)
	wasKilled := domain.killed
	spinlock.rw_write_unlock(&domain.lock)
	if wasKilled do return
	protdomain_unregister(domain)
	free(domain)
}

restore_current_domain_cr3 :: proc "contextless" () {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil do return
	if cpu.rrCurrent.domain == nil do return
	domain_switch_cr3(cpu.rrCurrent.domain)
}

execution_enqueue :: proc "contextless" (e: ^Execution, cpu: ^CpuState) {
	print.kassert(e != nil, "execution_enqueue: nil execution")
	print.kassert(cpu != nil, "execution_enqueue: nil CPU")
	if e == nil || cpu == nil do return
	print.kassert(e.domain != nil, "execution_enqueue: nil domain")
	if e.domain == nil do return
	print.kassert(
		intrinsics.atomic_load(&e.domain.executionCount) > 0,
		"execution_enqueue: domain has no executions",
	)

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

execution_enqueue_front :: proc "contextless" (e: ^Execution, cpu: ^CpuState) {
	print.kassert(e != nil, "execution_enqueue_front: nil execution")
	print.kassert(cpu != nil, "execution_enqueue_front: nil CPU")
	if e == nil || cpu == nil do return
	print.kassert(e.domain != nil, "execution_enqueue_front: nil domain")
	if e.domain == nil do return
	print.kassert(
		intrinsics.atomic_load(&e.domain.executionCount) > 0,
		"execution_enqueue_front: domain has no executions",
	)

	{
		spinlock.lock(&cpu.rrLock)
		defer spinlock.unlock(&cpu.rrLock)

		e.next = cpu.rrHead
		cpu.rrHead = e
		if cpu.rrTail == nil do cpu.rrTail = e
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
	context = gKernelCtx
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

	if exec.domain.killed {
		cpu.rrCurrent = nil
		execution_release(exec)
		return true
	}

	print.kassert(exec.domain.pml4 != 0, "rn: pml4 zero")
	print.kassert(exec.state.rip != 0, "rn: rip zero")
	print.kassert(exec.state.rsp != 0, "rn: rsp zero")
	print.kassert(exec.state.cs == 0x2B, "rn: bad cs")
	print.kassert(exec.state.ss == 0x23, "rn: bad ss")
	print.kassert(exec.state.rsp % 16 == 8, "run_next_execution: rsp unaligned")
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
	lapic_disable_deadline()
	ah.monitor_asm(rawptr(&cpu.rrHead))
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

	alreadyKilled: bool
	execs: [dynamic]^Execution
	{
		spinlock.rw_write_lock(&domain.lock)
		defer spinlock.rw_write_unlock(&domain.lock)

		if domain.killed {
			alreadyKilled = true
		} else {
			domain.killed = true
			execs = make([dynamic]^Execution, len(domain.executions))
			copy(execs[:], domain.executions[:])
			if len(execs) == 0 {
				domain_reclaim_locked(domain)
			}
		}
	}
	if alreadyKilled do return

	if len(execs) == 0 {
		delete(execs)
		protdomain_unregister(domain)
		free(domain)
		return
	}

	for exec in execs {
		if interrupt_release_execution(exec) {
			execution_release(exec)
		}
	}
	delete(execs)

	for cpu in cpus {
		send_ipi(cpu.apicId, VECTOR_APIC_IPI)
	}

	for intrinsics.atomic_load(&domain.executionCount) > 0 {
		ah.cpu_pause()
	}

	{
		spinlock.rw_write_lock(&domain.lock)
		defer spinlock.rw_write_unlock(&domain.lock)
		print.kassert(domain.pml4 == 0, "domain_destroy: reclaim not done by last release")
	}

	protdomain_unregister(domain)
	free(domain)
}

domain_reclaim_locked :: proc(domain: ^ProtectionDomain) {
	print.kassert(domain != nil, "domain_reclaim_locked: nil domain")
	if domain == nil do return
	print.kassert(
		intrinsics.atomic_load(&domain.executionCount) == 0,
		"domain_reclaim_locked: executions still attached",
	)
	print.kassert(domain.pml4 != 0, "domain_destroy: paging already destroyed")
	print.kassert(domain.pml4 != pmm.kernelPML4, "domain_destroy: kernel PML4 passed")

	kernel_switch_cr3()

	pcid_free(domain.pcid)

	delete(domain.resources)
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
	run_abort()
}
