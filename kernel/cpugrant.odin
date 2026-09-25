package kernel
import ah "../asm_helpers"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "core:container/bit_array"
import "core:mem"
import "print"

GRANT_MAX_CHARGE_TICKS :: u64(1) << 40
GRANT_REBASE_FLOOR :: u64(1) << 62
GRANT_SLICE_MS :: 5
CPU_GRANT_STARTING_CAPACITY :: 128
USER_RFLAGS_FORCED :: u64(0x202)

#assert(userschedule.SCHED_WEIGHT_TOTAL <= u64(1) << 20)
#assert(
	GRANT_REBASE_FLOOR + 2 * GRANT_MAX_CHARGE_TICKS * userschedule.SCHED_WEIGHT_TOTAL <=
	max(u64) / 2,
)
#assert(size_of(userschedule.UserSaveArea) <= shared.PAGE_SIZE)

GrantSleepState :: bit_field u64 {
	idleLevel: IdleLevel | 8,
	reserved:  u64       | 55,
	asleep:    bool      | 1,
}
#assert(size_of(GrantSleepState) == size_of(u64))

CpuGrant :: struct {
	saveArea:    ^userschedule.UserSaveArea,
	weight:      u64,
	domain:      ^ProtectionDomain,
	virtualTime: u64,
	sleepState:  GrantSleepState,
}

TRAMPOLINE_STACK_SIZE :: 256
trampolineStacksBase: u64

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_read_cpustate :: proc() -> ^CpuState ---
		run_resume :: proc(targetCr3: u64, area: ^userschedule.UserSaveArea) -> ! ---
		user_save_area_store :: proc(area: ^userschedule.UserSaveArea, frame: ^InterruptFrame, fx: ^[512]u8) ---
		user_access_begin :: proc() ---
		user_access_end :: proc() ---
		run_abort :: proc() -> ! ---
		cpu_idle_loop :: proc() -> ! ---
	}
} else {
	@(thread_local)
	testCpu: ^CpuState

	gs_read_cpustate :: proc "contextless" () -> ^CpuState {return testCpu}
	run_resume :: proc "contextless" (
		targetCr3: u64,
		area: ^userschedule.UserSaveArea,
	) -> ! {for {}}
	user_save_area_store :: proc "contextless" (
		area: ^userschedule.UserSaveArea,
		frame: ^InterruptFrame,
		fx: ^[512]u8,
	) {}
	user_access_begin :: proc "contextless" () {}
	user_access_end :: proc "contextless" () {}
	run_abort :: proc "contextless" () -> ! {for {}}
	cpu_idle_loop :: proc "contextless" () -> ! {for {}}
}

grant_insert_index_DOESNT_LOCK :: proc(cpu: ^CpuState, grant: CpuGrant) -> int {
	low := 0
	high := len(cpu.grants)
	for low < high {
		mid := low + (high - low) / 2
		if grant.virtualTime > cpu.grants[mid].virtualTime {
			high = mid
		} else {
			low = mid + 1
		}
	}
	return low
}

grant_insert_DOESNT_LOCK :: proc(cpu: ^CpuState, grant: CpuGrant) -> mem.Allocator_Error {
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)
	assert(grant.weight > 0 && grant.weight <= userschedule.SCHED_WEIGHT_TOTAL)
	_ = inject_at(&cpu.grants, grant_insert_index_DOESNT_LOCK(cpu, grant), grant) or_return
	return .None
}

runnable_weight_add_DOESNT_LOCK :: proc(cpu: ^CpuState, weight: u64) {
	intrinsics.atomic_store(&cpu.info.runnableWeight, cpu.info.runnableWeight + weight)
}

runnable_weight_sub_DOESNT_LOCK :: proc(cpu: ^CpuState, weight: u64) {
	assert(cpu.info.runnableWeight >= weight)
	intrinsics.atomic_store(&cpu.info.runnableWeight, cpu.info.runnableWeight - weight)
}

grant_find_DOESNT_LOCK :: proc(
	cpu: ^CpuState,
	domain: ^ProtectionDomain,
) -> (
	grant: ^CpuGrant,
	queueIdx: int,
) {
	if cpu.currentGrant.domain == domain && cpu.currentGrant.weight > 0 {
		return &cpu.currentGrant, -1
	}
	for &queued, idx in cpu.grants {
		if queued.domain == domain do return &queued, idx
	}
	return nil, -1
}

grant_kill_DOESNT_LOCK :: proc(cpu: ^CpuState, domain: ^ProtectionDomain) {
	grant, queueIdx := grant_find_DOESNT_LOCK(cpu, domain)
	assert(grant != nil)
	assert(grant.weight > 0)

	domain.weightFree += grant.weight
	assert(domain.weightFree <= userschedule.SCHED_WEIGHT_TOTAL)
	unset := bit_array.unset(&domain.grantCpus, cpu.index)
	assert(unset)
	if !grant.sleepState.asleep do runnable_weight_sub_DOESNT_LOCK(cpu, grant.weight)

	if queueIdx >= 0 {
		ordered_remove(&cpu.grants, queueIdx)
		return
	}
	intrinsics.atomic_store(&grant.weight, 0)
	grant_wake_cpu(cpu)
}

grant_wake_cpu :: proc(cpu: ^CpuState) {
	intrinsics.atomic_add(&cpu.wakeEvent, 1)
	if gs_read_cpustate() == cpu do return
	send_ipi(cpu.apicId, VECTOR_APIC_IPI)
}

grant_spawn :: proc(
	domain: ^ProtectionDomain,
	cpu: ^CpuState,
	saveArea: ^userschedule.UserSaveArea,
	weight: u64,
) -> syscalls.GrantError {
	assert(domain != nil)
	assert(cpu != nil)

	if saveArea == nil || uintptr(saveArea) % align_of(userschedule.UserSaveArea) != 0 do return .InvalidSaveArea

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	if bit_array.get(&domain.grantCpus, cpu.index) do return .AlreadyOnCpu
	if weight == 0 || weight > domain.weightFree do return .InsufficientWeight
	if !user_range_accessible(domain, u64(uintptr(saveArea)), size_of(userschedule.UserSaveArea), true) do return .InvalidSaveArea

	{
		spinlock.lock(&cpu.grantLock)
		defer spinlock.unlock(&cpu.grantLock)

		if !cpu.info.online do return .InvalidCpu

		charge := min(tscTicksPerMs * GRANT_SLICE_MS, GRANT_MAX_CHARGE_TICKS)
		grant := CpuGrant {
			saveArea = saveArea,
			weight = weight,
			domain = domain,
			virtualTime = cpu.floorVirtualTime + charge * userschedule.SCHED_WEIGHT_TOTAL / weight,
			sleepState = {idleLevel = cpu_deepest_idle_level(cpu)},
		}
		if grant_insert_DOESNT_LOCK(cpu, grant) != nil do return .OutOfMemory
		runnable_weight_add_DOESNT_LOCK(cpu, weight)
	}

	domain.weightFree -= weight
	set := bit_array.set(&domain.grantCpus, cpu.index)
	assert(set)
	grant_wake_cpu(cpu)
	return .None
}

grant_edit :: proc(domain: ^ProtectionDomain, cpu: ^CpuState, weight: u64) -> syscalls.GrantError {
	assert(domain != nil)
	assert(cpu != nil)

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	if !bit_array.get(&domain.grantCpus, cpu.index) do return .NotOnCpu

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)

	if weight == 0 {
		grant_kill_DOESNT_LOCK(cpu, domain)
		return .None
	}

	grant, _ := grant_find_DOESNT_LOCK(cpu, domain)
	assert(grant != nil)
	assert(grant.weight > 0)
	if weight > userschedule.SCHED_WEIGHT_TOTAL || weight > grant.weight + domain.weightFree do return .InsufficientWeight

	domain.weightFree = domain.weightFree + grant.weight - weight
	assert(domain.weightFree <= userschedule.SCHED_WEIGHT_TOTAL)
	if !grant.sleepState.asleep {
		runnable_weight_add_DOESNT_LOCK(cpu, weight)
		runnable_weight_sub_DOESNT_LOCK(cpu, grant.weight)
	}
	intrinsics.atomic_store(&grant.weight, weight)
	return .None
}

grant_kill_all :: proc(domain: ^ProtectionDomain) {
	assert(domain != nil)
	{
		spinlock.rw_write_lock(&domain.lock)
		defer spinlock.rw_write_unlock(&domain.lock)

		for &cpu in cpus {
			if !bit_array.get(&domain.grantCpus, cpu.index) do continue
			spinlock.lock(&cpu.grantLock)
			grant_kill_DOESNT_LOCK(&cpu, domain)
			spinlock.unlock(&cpu.grantLock)
		}
		assert(domain.weightFree == userschedule.SCHED_WEIGHT_TOTAL)
		domain.weightFree = 0
	}
	for &cpu in cpus {
		for intrinsics.atomic_load(&cpu.currentGrant.domain) == domain {
			intrinsics.cpu_relax()
		}
	}
}

@(export)
cpu_next_grant :: proc "c" () -> bool {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	assert(cpu != nil)
	if cpu == nil do return false

	selected: CpuGrant
	{
		spinlock.lock(&cpu.grantLock)
		defer spinlock.unlock(&cpu.grantLock)

		bestIdle := cpu_deepest_idle_level(cpu)
		found := false
		for idx := len(cpu.grants) - 1; idx >= 0; idx -= 1 {
			grant := cpu.grants[idx]
			if grant.sleepState.asleep {
				bestIdle = min(bestIdle, grant.sleepState.idleLevel)
				continue
			}

			selected = grant
			ordered_remove(&cpu.grants, idx)
			found = true
			break
		}
		cpu.selectedIdleLevel = bestIdle

		if !found {
			lapic_disable_deadline()
			return false
		}

		assert(selected.weight > 0)
		assert(selected.virtualTime >= cpu.floorVirtualTime)
		cpu.floorVirtualTime = selected.virtualTime
		cpu.currentGrant = selected
		cpu.grantStartTsc = ah.rdtsc_asm()
		intrinsics.atomic_add(&cpu.tlbEpoch, 1)
	}

	lapic_set_deadline(tscTicksPerMs * GRANT_SLICE_MS)
	run_resume(selected.domain.pml4 | u64(selected.domain.pcid), selected.saveArea)
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
		if cpu == nil do return 0
		for state in cpu.idleInfo.states {
			if state.level == cpu.selectedIdleLevel do return state.mwaitHint
		}
		return 0
	}
}

cpu_deepest_idle_level :: proc "contextless" (cpu: ^CpuState) -> IdleLevel {
	if len(cpu.idleInfo.states) == 0 do return 0
	return cpu.idleInfo.states[len(cpu.idleInfo.states) - 1].level
}

restore_current_domain_cr3 :: proc "contextless" () {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil do return
	domain_switch_cr3(cpu.currentGrant.domain)
}

grant_rebase_virtual_times_DOESNT_LOCK :: proc(cpu: ^CpuState) {
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

grant_account_current_DOESNT_LOCK :: proc(cpu: ^CpuState) -> CpuGrant {
	assert(cpu.currentGrant.domain != nil)
	assert(
		cpu.currentGrant.weight > 0 && cpu.currentGrant.weight <= userschedule.SCHED_WEIGHT_TOTAL,
	)
	assert(cpu.currentGrant.virtualTime >= cpu.floorVirtualTime)

	now := ah.rdtsc_asm()
	elapsed, clockWrapped := intrinsics.overflow_sub(now, cpu.grantStartTsc)
	assert(!clockWrapped, "grant clock moved backwards")
	elapsed = min(elapsed, GRANT_MAX_CHARGE_TICKS)

	if cpu.floorVirtualTime >= GRANT_REBASE_FLOOR do grant_rebase_virtual_times_DOESNT_LOCK(cpu)
	assert(cpu.floorVirtualTime < GRANT_REBASE_FLOOR)
	assert(
		cpu.currentGrant.virtualTime - cpu.floorVirtualTime <=
		2 * GRANT_MAX_CHARGE_TICKS * userschedule.SCHED_WEIGHT_TOTAL,
	)

	cpu.currentGrant.virtualTime +=
		elapsed * userschedule.SCHED_WEIGHT_TOTAL / cpu.currentGrant.weight
	cpu.grantStartTsc = now
	return cpu.currentGrant
}

grant_stop_current :: proc(cpu: ^CpuState) {
	assert(cpu != nil)
	assert(cpu.currentGrant.domain != nil)
	assert(!cpu.currentGrant.sleepState.asleep)

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)
	defer {
		cpu.currentGrant = {}
		cpu.grantStartTsc = 0
	}

	if cpu.currentGrant.weight == 0 do return

	grant := grant_account_current_DOESNT_LOCK(cpu)
	err := grant_insert_DOESNT_LOCK(cpu, grant)
	print.kensure(err == {}, "grant requeue failed")
}

grant_wake :: proc(cpu: ^CpuState, domain: ^ProtectionDomain) -> bool {
	assert(cpu != nil)
	assert(domain != nil)

	spinlock.lock(&cpu.grantLock)
	defer spinlock.unlock(&cpu.grantLock)

	grant, queueIdx := grant_find_DOESNT_LOCK(cpu, domain)
	if grant == nil || queueIdx < 0 || !grant.sleepState.asleep do return false

	woken := grant^
	woken.sleepState.asleep = false
	woken.virtualTime = max(woken.virtualTime, cpu.floorVirtualTime)
	ordered_remove(&cpu.grants, queueIdx)
	err := grant_insert_DOESNT_LOCK(cpu, woken)
	assert(err == nil)
	runnable_weight_add_DOESNT_LOCK(cpu, woken.weight)
	grant_wake_cpu(cpu)
	return true
}

grant_exit_current :: proc(cpu: ^CpuState) {
	assert(cpu != nil)
	domain := cpu.currentGrant.domain
	assert(domain != nil)
	{
		spinlock.rw_write_lock(&domain.lock)
		defer spinlock.rw_write_unlock(&domain.lock)
		spinlock.lock(&cpu.grantLock)
		defer spinlock.unlock(&cpu.grantLock)
		if cpu.currentGrant.weight > 0 do grant_kill_DOESNT_LOCK(cpu, domain)
	}
	grant_stop_current(cpu)
}

grant_preempt :: proc(cpu: ^CpuState, frame: ^InterruptFrame) -> ! {
	assert(cpu != nil)
	grant := &cpu.currentGrant
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)

	if intrinsics.atomic_load(&grant.weight) != 0 {
		domain_switch_cr3(grant.domain)
		user_save_area_store(grant.saveArea, frame, &cpu.userFx)
		kernel_switch_cr3()
	}
	grant_stop_current(cpu)
	run_abort()
}

user_access_faulted :: proc "contextless" (frame: ^InterruptFrame) -> bool {
	VECTOR_INVALID_OPCODE :: 6
	VECTOR_GENERAL_PROTECTION :: 13
	VECTOR_PAGE_FAULT :: 14
	switch frame.interruptNumber {
	case VECTOR_INVALID_OPCODE, VECTOR_GENERAL_PROTECTION, VECTOR_PAGE_FAULT:
	case:
		return false
	}
	begin := u64(uintptr(rawptr(user_access_begin)))
	end := u64(uintptr(rawptr(user_access_end)))
	return frame.rip >= begin && frame.rip < end
}
