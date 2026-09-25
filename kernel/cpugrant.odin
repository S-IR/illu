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

SCHED_WEIGHT_TOTAL :: u64(1_000)

CpuGrant :: struct {
	domain:                                 ^ProtectionDomain,
	weight:                                 u64,
	virtualTime:                            u64,
	accountingRemainder:                    u64,
	entryRIP, entryRSP:                     u64,
	entryRDI, entryRSI, entryRDX, entryRCX: u64,
	saveArea:                               ^syscalls.UserSaveArea,
	sleepState:                             GrantSleepState,
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

	_, err = inject_at(&cpu.grants, low, grant)
	if err != {} do return err


	grant_wake_cpu(cpu)
	return .None
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
	if len(cpu.grants) > 0 {
		grant.virtualTime = min(grant.virtualTime, cpu.grants[len(cpu.grants) - 1].virtualTime)
	}
	grant.accountingRemainder = 0
	append(&cpu.grants, grant) or_return
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

	minimum := max(u64)
	if cpu.currentGrant.domain != nil {
		minimum = min(minimum, cpu.currentGrant.virtualTime)
	}

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)
	for grant in cpu.grants {
		if grant.domain != nil {
			minimum = min(minimum, grant.virtualTime)
		}
	}
	if minimum == max(u64) || minimum == 0 do return
	if cpu.currentGrant.domain != nil {
		cpu.currentGrant.virtualTime -= minimum
	}
	for &grant in cpu.grants {
		if grant.domain != nil do grant.virtualTime -= minimum
	}
	cpu.floorVirtualTime -= min(cpu.floorVirtualTime, minimum)
}

grant_account_current :: proc(cpu: ^CpuState) -> CpuGrant {
	grant := cpu.currentGrant
	assert(grant.domain != nil)
	assert(grant.weight > 0 && grant.weight <= SCHED_WEIGHT_TOTAL)

	now := ah.rdtsc_asm()
	elapsed, clockWrapped := intrinsics.overflow_sub(now, cpu.grantStartTsc)
	assert(!clockWrapped, "grant clock moved backwards")

	whole := elapsed / grant.weight
	fraction := elapsed % grant.weight
	rem, remOverflow := intrinsics.overflow_add(fraction, grant.accountingRemainder)
	assert(!remOverflow, "grant accounting remainder overflow")

	carry := rem / grant.weight
	grant.accountingRemainder = rem % grant.weight
	delta, deltaOverflow := intrinsics.overflow_add(whole, carry)
	if deltaOverflow {
		grant.virtualTime = max(u64)
	} else {
		next, timeOverflow := intrinsics.overflow_add(grant.virtualTime, delta)
		if timeOverflow {
			cpu.currentGrant = grant
			grant_rebase_virtual_times(cpu)
			grant = cpu.currentGrant
			next, timeOverflow = intrinsics.overflow_add(grant.virtualTime, delta)
			assert(!timeOverflow, "grant virtual time overflow after rebase")
		}
		grant.virtualTime = next
	}

	cpu.currentGrant = grant
	cpu.grantStartTsc = now
	return grant
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

	for &grant in cpu.grants {
		if grant.domain != domain || !grant.sleepState.asleep do continue

		grant.sleepState.asleep = false
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
