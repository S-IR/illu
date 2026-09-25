package kernel
import ah "../asm_helpers"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"
GrantSleepState :: bit_field u64 {
	idleLevel: IdleLevel | 8,
	reserved:  u64       | 55,
	asleep:    bool      | 1,
}

#assert(size_of(GrantSleepState) == size_of(u64))

SCHED_WEIGHT_TOTAL :: u64(1_000_000)
GRANT_MAX_CHARGE_TICKS :: u64(1) << 40
GRANT_REBASE_FLOOR :: u64(1) << 62

#assert(SCHED_WEIGHT_TOTAL <= u64(1) << 20)
#assert(GRANT_REBASE_FLOOR + GRANT_MAX_CHARGE_TICKS * SCHED_WEIGHT_TOTAL <= max(u64) / 2)

CpuGrant :: struct {
	saveArea:    ^syscalls.UserSaveArea,
	weight:      u64,
	domain:      ^ProtectionDomain,
	virtualTime: u64,
	sleepState:  GrantSleepState,
}
// Larger values are stored earlier.
grant_before :: proc(a, b: CpuGrant) -> bool {
	return a.virtualTime > b.virtualTime
}
CPU_GRANT_STARTING_CAPACITY :: 128
//RETURNS INVALID PTR ON CPU NIL
grant_insert :: proc(cpu: ^CpuState, grant: CpuGrant) -> (err: mem.Allocator_Error) {
	assert(cpu != nil)
	if cpu == nil do return .Invalid_Pointer
	assert(grant.weight > 0 && grant.weight <= SCHED_WEIGHT_TOTAL)

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)

	_ = inject_at(&cpu.grants, grant_insert_index_LOCKED(cpu, grant), grant) or_return
	grant_wake_cpu(cpu)
	return .None
}

grant_insert_index_LOCKED :: proc(cpu: ^CpuState, grant: CpuGrant) -> int {
	low := 0
	high := len(cpu.grants)

	for low < high {
		mid := low + (high - low) / 2

		if grant_before(grant, cpu.grants[mid]) {
			high = mid
		} else {
			low = mid + 1
		}
	}
	return low
}
grant_add_new :: proc(cpu: ^CpuState, grant: CpuGrant) -> mem.Allocator_Error {
	assert(cpu != nil)
	assert(grant.domain != nil)
	assert(grant.weight > 0 && grant.weight <= SCHED_WEIGHT_TOTAL)
	assert(grant.saveArea != nil)

	grant := grant

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)

	grant.virtualTime = cpu.floorVirtualTime
	_ = inject_at(&cpu.grants, grant_insert_index_LOCKED(cpu, grant), grant) or_return
	grant_wake_cpu(cpu)
	return .None
}

@(export)
cpu_next_grant :: proc "c" () -> bool {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	assert(cpu != nil)

	if cpu == nil do return false

	selected: CpuGrant
	found := false
	bestIdle: IdleLevel
	{
		spinlock.lock(&cpu.grantLock)
		defer spinlock.unlock(&cpu.grantLock)

		bestIdle = cpu_deepest_idle_level(cpu)

		for idx := len(cpu.grants) - 1; idx >= 0; idx -= 1 {
			grant := &cpu.grants[idx]

			if grant.sleepState.asleep {
				if grant.sleepState.idleLevel < bestIdle {
					bestIdle = grant.sleepState.idleLevel
				}
				continue
			}

			selected = grant^
			ordered_remove(&cpu.grants, idx)
			found = true
			assert(selected.virtualTime >= cpu.floorVirtualTime)
			cpu.floorVirtualTime = selected.virtualTime

			break
		}

		cpu.selectedIdleLevel = bestIdle
	}

	if !found {
		lapic_disable_deadline()
		return false
	}

	cpu.currentGrant = selected
	cpu.grantStartTsc = ah.rdtsc_asm()

	area: syscalls.UserSaveArea
	if !grant_read_save_area(selected, &area) {
		grant_stop_current(cpu, .Exit)
		return true
	}
	lapic_set_deadline(tscTicksPerMs * GRANT_SLICE_MS)
	run_resume(selected.domain.pml4, &area)
}

when ODIN_ARCH == .amd64 {
	@(export)
	cpu_idle_mwait_address :: proc "c" () -> u64 {
		context = gKernelCtx

		cpu := gs_read_cpustate()
		if cpu == nil do return 0

		return u64(uintptr(&cpu.wakeEvent))
	}

	@(export)
	cpu_idle_mwait_hint :: proc "c" () -> u32 {
		context = gKernelCtx

		cpu := gs_read_cpustate()
		if cpu == nil || len(cpu.idleInfo.states) == 0 do return 0

		for state in cpu.idleInfo.states {
			if state.level == cpu.selectedIdleLevel {
				return state.mwaitHint
			}
		}

		return 0
	}
}

cpu_deepest_idle_level :: proc "contextless" (cpu: ^CpuState) -> IdleLevel {
	if len(cpu.idleInfo.states) == 0 do return 0
	return cpu.idleInfo.states[len(cpu.idleInfo.states) - 1].level
}

TRAMPOLINE_STACK_SIZE :: 256
trampolineStacksBase: u64

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_read_cpustate :: proc() -> ^CpuState ---
		run_resume :: proc(targetPml4: u64, area: ^syscalls.UserSaveArea) -> ! ---
		run_abort :: proc() -> ! ---
		cpu_idle_loop :: proc() -> ! ---
	}
} else {
	@(thread_local)
	testCpu: ^CpuState

	gs_read_cpustate :: proc "contextless" () -> ^CpuState {return testCpu}
	run_resume :: proc "contextless" (targetPml4: u64, area: ^syscalls.UserSaveArea) -> ! {for {}}
	run_abort :: proc "contextless" () -> ! {for {}}
	cpu_idle_loop :: proc "contextless" () -> ! {for {}}
}

restore_current_domain_cr3 :: proc "contextless" () {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil do return
	domain_switch_cr3(cpu.currentGrant.domain)
}


GrantStopReason :: enum {
	Yield,
	Sleep,
	Exit,
}

grant_rebase_virtual_times :: proc(cpu: ^CpuState) {
	assert(cpu != nil)
	if cpu == nil do return

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)

	base := cpu.floorVirtualTime
	if cpu.currentGrant.domain != nil {
		assert(cpu.currentGrant.virtualTime >= base)
		cpu.currentGrant.virtualTime -= base
	}
	for &grant in cpu.grants {
		grant.virtualTime -= min(grant.virtualTime, base)
	}
	cpu.floorVirtualTime = 0
}

grant_account_current :: proc(cpu: ^CpuState) -> CpuGrant {
	assert(cpu.currentGrant.domain != nil)
	assert(cpu.currentGrant.weight > 0 && cpu.currentGrant.weight <= SCHED_WEIGHT_TOTAL)
	assert(cpu.currentGrant.virtualTime >= cpu.floorVirtualTime)

	now := ah.rdtsc_asm()
	elapsed, clockWrapped := intrinsics.overflow_sub(now, cpu.grantStartTsc)
	assert(!clockWrapped, "grant clock moved backwards")
	elapsed = min(elapsed, GRANT_MAX_CHARGE_TICKS)

	if cpu.floorVirtualTime >= GRANT_REBASE_FLOOR do grant_rebase_virtual_times(cpu)
	assert(cpu.floorVirtualTime < GRANT_REBASE_FLOOR)
	assert(
		cpu.currentGrant.virtualTime - cpu.floorVirtualTime <=
		GRANT_MAX_CHARGE_TICKS * SCHED_WEIGHT_TOTAL,
	)

	cpu.currentGrant.virtualTime += elapsed * SCHED_WEIGHT_TOTAL / cpu.currentGrant.weight
	cpu.grantStartTsc = now
	return cpu.currentGrant
}

grant_stop_current :: proc(cpu: ^CpuState, reason: GrantStopReason) {
	assert(cpu != nil)
	if cpu == nil || cpu.currentGrant.domain == nil do return

	grant := grant_account_current(cpu)

	switch reason {
	case .Yield:
		err := grant_insert(cpu, grant)
		print.kensure(err == {}, "grant requeue failed")

	case .Sleep:
		grant.sleepState.asleep = true
		err := grant_insert(cpu, grant)
		print.kensure(err == {}, "grant sleep requeue failed")

	case .Exit:
	// Finished grants are not reinserted.
	}

	cpu.currentGrant = {}
	cpu.grantStartTsc = 0
}

grant_wake_cpu :: proc(cpu: ^CpuState) {
	intrinsics.atomic_add(&cpu.wakeEvent, 1)

	current := gs_read_cpustate()
	if current != nil && current == cpu do return

	send_ipi(cpu.apicId, VECTOR_APIC_IPI)
}
grant_sleep_current :: proc(cpu: ^CpuState, idleLevel: IdleLevel) {
	if cpu == nil || cpu.currentGrant.domain == nil do return

	cpu.currentGrant.sleepState = GrantSleepState {
		idleLevel = idleLevel,
		asleep    = true,
	}

	grant_stop_current(cpu, .Sleep)
	run_abort()
}

grant_wake :: proc(cpu: ^CpuState, domain: ^ProtectionDomain) -> bool {
	if cpu == nil || domain == nil do return false

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)

	for grant, idx in cpu.grants {
		if grant.domain != domain || !grant.sleepState.asleep do continue

		woken := grant
		woken.sleepState.asleep = false
		woken.virtualTime = max(woken.virtualTime, cpu.floorVirtualTime)
		ordered_remove(&cpu.grants, idx)
		_, err := inject_at(&cpu.grants, grant_insert_index_LOCKED(cpu, woken), woken)
		assert(err == nil)
		grant_wake_cpu(cpu)
		return true
	}

	return false
}

GRANT_SLICE_MS :: 5
USER_RFLAGS_MASK :: u64(0xCD5)
USER_RFLAGS_FORCED :: u64(0x202)


grant_preempt :: proc(cpu: ^CpuState, frame: ^InterruptFrame) -> ! {
	assert(cpu != nil)
	grant := &cpu.currentGrant
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)
	domain := grant.domain

	saved := false
	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		if pmm.user_range_accessible(
			domain.pml4,
			u64(uintptr(grant.saveArea)),
			size_of(syscalls.UserSaveArea),
			write = true,
		) {
			area := grant.saveArea
			area.fx = cpu.userFx
			area.rax, area.rbx, area.rcx, area.rdx = frame.rax, frame.rbx, frame.rcx, frame.rdx
			area.rsi, area.rdi, area.rbp = frame.rsi, frame.rdi, frame.rbp
			area.r8, area.r9, area.r10, area.r11 = frame.r8, frame.r9, frame.r10, frame.r11
			area.r12, area.r13, area.r14, area.r15 = frame.r12, frame.r13, frame.r14, frame.r15
			area.rip, area.rsp, area.rflags = frame.rip, frame.rsp, frame.rflags
			saved = true
		}
	}

	grant_stop_current(cpu, saved ? .Yield : .Exit)
	run_abort()
}

grant_read_save_area :: proc(grant: CpuGrant, out: ^syscalls.UserSaveArea) -> bool {
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)
	domain := grant.domain

	spinlock.rw_read_lock(&domain.lock)
	defer spinlock.rw_read_unlock(&domain.lock)
	if !pmm.user_range_accessible(
		domain.pml4,
		u64(uintptr(grant.saveArea)),
		size_of(syscalls.UserSaveArea),
		write = false,
	) {
		return false
	}
	out^ = grant.saveArea^
	out.rflags = (out.rflags & USER_RFLAGS_MASK) | USER_RFLAGS_FORCED
	mxcsr := (^u32)(&out.fx[FX_MXCSR_OFFSET])
	mxcsr^ &= MXCSR_SAFE_MASK
	return true
}
