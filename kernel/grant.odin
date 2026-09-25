package kernel

import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "core:container/bit_array"
import "core:mem"
import "print"

GRANT_SLICE_MS :: 5
GRANT_VIRTUAL_TIME_SPAN :: u64(1) << 62
CPU_GRANT_STARTING_CAPACITY :: 128

#assert(userschedule.SCHED_WEIGHT_TOTAL <= u64(1) << 20)
#assert(size_of(userschedule.UserSaveArea) <= shared.PAGE_SIZE)
#assert(u64(syscalls.SchedulerEnterReason.Resume) == 2)

IdleLevel :: distinct u8

GrantSleepState :: bit_field u64 {
	idleLevel: IdleLevel | 8,
	reserved:  u64       | 55,
	asleep:    bool      | 1,
}
#assert(size_of(GrantSleepState) == size_of(u64))

CpuGrant :: struct {
	saveArea:    ^userschedule.UserSaveArea,
	entry:       u64,
	weight:      u64,
	domain:      ^ProtectionDomain,
	virtualTime: u64,
	sleepState:  GrantSleepState,
}

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_read_cpustate :: proc() -> ^CpuState ---
		run_resume :: proc(targetCr3: u64, entry: u64, area: ^userschedule.UserSaveArea) -> ! ---
		run_abort :: proc() -> ! ---
		user_save_area_store :: proc(area: ^userschedule.UserSaveArea, frame: ^InterruptFrame) ---
		user_access_begin :: proc() ---
		user_access_end :: proc() ---
		cpu_cli :: proc() ---
		cpu_monitor :: proc(address: rawptr) ---
		cpu_mwait :: proc(hint: u32) ---
		cpu_halt :: proc() ---
	}
} else {
	@(thread_local)
	testCpu: ^CpuState

	gs_read_cpustate :: proc "contextless" () -> ^CpuState {return testCpu}
	run_resume :: proc "contextless" (targetCr3: u64, entry: u64, area: ^userschedule.UserSaveArea) -> ! {for {}}
	run_abort :: proc "contextless" () -> ! {for {}}
	user_save_area_store :: proc "contextless" (area: ^userschedule.UserSaveArea, frame: ^InterruptFrame) {}
	user_access_begin :: proc "contextless" () {}
	user_access_end :: proc "contextless" () {}
	cpu_cli :: proc "contextless" () {}
	cpu_monitor :: proc "contextless" (address: rawptr) {}
	cpu_mwait :: proc "contextless" (hint: u32) {}
	cpu_halt :: proc "contextless" () {}
}

grant_charge :: proc "contextless" (weight: u64) -> u64 {
	return tscTicksPerMs * GRANT_SLICE_MS * userschedule.SCHED_WEIGHT_TOTAL / weight
}

cpu_kick :: proc "contextless" (cpu: ^CpuState) {
	if cpu == gs_read_cpustate() do return
	send_ipi(cpu_info(cpu).apicId, VECTOR_APIC_IPI)
}

grant_enqueue :: proc(cpu: ^CpuState, grant: CpuGrant) -> mem.Allocator_Error {
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)
	assert(grant.entry != 0 && grant.entry < USER_ADDR_END)
	assert(grant.weight > 0 && grant.weight <= userschedule.SCHED_WEIGHT_TOTAL)
	assert(grant.virtualTime - cpu.floorVirtualTime < GRANT_VIRTUAL_TIME_SPAN)
	low, high := 0, len(cpu.grants)
	for low < high {
		mid := low + (high - low) / 2
		if i64(grant.virtualTime - cpu.grants[mid].virtualTime) > 0 {
			high = mid
		} else {
			low = mid + 1
		}
	}
	_ = inject_at(&cpu.grants, low, grant) or_return
	return .None
}

grant_find_locked :: proc(cpu: ^CpuState, domain: ^ProtectionDomain) -> ^CpuGrant {
	if cpu.currentGrant.domain == domain && cpu.currentGrant.weight > 0 do return &cpu.currentGrant
	for &queued in cpu.grants {
		if queued.domain == domain do return &queued
	}
	return nil
}

grant_kill_locked :: proc(cpu: ^CpuState, domain: ^ProtectionDomain) {
	grant := grant_find_locked(cpu, domain)
	assert(grant != nil)
	killed := grant^
	assert(killed.weight > 0)

	if grant == &cpu.currentGrant {
		intrinsics.atomic_store(&grant.weight, 0)
		cpu_kick(cpu)
	} else {
		ordered_remove(&cpu.grants, mem.ptr_sub(grant, &cpu.grants[0]))
	}

	domain.weightFree += killed.weight
	assert(domain.weightFree <= userschedule.SCHED_WEIGHT_TOTAL)
	unset := bit_array.unset(&domain.grantCpus, cpu_index(cpu))
	assert(unset)

	if killed.sleepState.asleep do return
	info := cpu_info(cpu)
	assert(info.runnableWeight >= killed.weight)
	intrinsics.atomic_store(&info.runnableWeight, info.runnableWeight - killed.weight)
}

grant_spawn :: proc(
	domain: ^ProtectionDomain,
	cpu: ^CpuState,
	saveArea: ^userschedule.UserSaveArea,
	entry: u64,
	weight: u64,
) -> syscalls.GrantError {
	assert(domain != nil)
	assert(cpu != nil)

	if saveArea == nil || uintptr(saveArea) % align_of(userschedule.UserSaveArea) != 0 do return .InvalidSaveArea
	if entry == 0 || entry >= USER_ADDR_END do return .InvalidEntry

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	if bit_array.get(&domain.grantCpus, cpu_index(cpu)) do return .AlreadyOnCpu
	if weight == 0 || weight > domain.weightFree do return .InsufficientWeight
	if !user_range_accessible(domain, u64(uintptr(saveArea)), size_of(userschedule.UserSaveArea), true) do return .InvalidSaveArea

	info := cpu_info(cpu)
	if !intrinsics.atomic_load(&info.online) do return .InvalidCpu

	{
		spinlock.lock(&cpu.lock)
		defer spinlock.unlock(&cpu.lock)

		grant := CpuGrant {
			saveArea = saveArea,
			entry = entry,
			weight = weight,
			domain = domain,
			virtualTime = cpu.floorVirtualTime + grant_charge(weight),
			sleepState = {idleLevel = IdleLevel(max(info.idleCount, 1) - 1)},
		}
		if grant_enqueue(cpu, grant) != nil do return .OutOfMemory
		intrinsics.atomic_store(&info.runnableWeight, info.runnableWeight + weight)
	}

	domain.weightFree -= weight
	set := bit_array.set(&domain.grantCpus, cpu_index(cpu))
	assert(set)
	cpu_kick(cpu)
	return .None
}

grant_edit :: proc(domain: ^ProtectionDomain, cpu: ^CpuState, weight: u64) -> syscalls.GrantError {
	assert(domain != nil)
	assert(cpu != nil)

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	if !bit_array.get(&domain.grantCpus, cpu_index(cpu)) do return .NotOnCpu

	spinlock.lock(&cpu.lock)
	defer spinlock.unlock(&cpu.lock)

	if weight == 0 {
		grant_kill_locked(cpu, domain)
		return .None
	}

	grant := grant_find_locked(cpu, domain)
	assert(grant != nil)
	assert(grant.weight + domain.weightFree <= userschedule.SCHED_WEIGHT_TOTAL)
	if weight > grant.weight + domain.weightFree do return .InsufficientWeight

	domain.weightFree = domain.weightFree + grant.weight - weight
	if !grant.sleepState.asleep {
		info := cpu_info(cpu)
		intrinsics.atomic_store(&info.runnableWeight, info.runnableWeight + weight - grant.weight)
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
			if !bit_array.get(&domain.grantCpus, cpu_index(&cpu)) do continue
			spinlock.lock(&cpu.lock)
			grant_kill_locked(&cpu, domain)
			spinlock.unlock(&cpu.lock)
		}
		assert(domain.weightFree == userschedule.SCHED_WEIGHT_TOTAL)
		domain.weightFree = 0
	}

	self := gs_read_cpustate()
	for &cpu in cpus {
		for intrinsics.atomic_load(&cpu.currentGrant.domain) == domain {
			grant_leave_if_killed(self)
			intrinsics.cpu_relax()
		}
	}
}

grant_leave_if_killed :: proc(cpu: ^CpuState) {
	if cpu.currentGrant.domain == nil || intrinsics.atomic_load(&cpu.currentGrant.weight) != 0 do return
	kernel_switch_cr3()
	spinlock.lock(&cpu.lock)
	defer spinlock.unlock(&cpu.lock)
	cpu.currentGrant = {}
}

@(export)
grant_loop :: proc "c" () -> ! {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	assert(cpu.currentGrant.domain == nil)
	info := cpu_info(cpu)

	for {
		cpu_cli()
		if info.idleCount > 0 do cpu_monitor(&info.runnableWeight)

		spinlock.lock(&cpu.lock)
		idleLevel := IdleLevel(max(info.idleCount, 1) - 1)
		for idx := len(cpu.grants) - 1; idx >= 0; idx -= 1 {
			grant := cpu.grants[idx]
			if grant.sleepState.asleep {
				idleLevel = min(idleLevel, grant.sleepState.idleLevel)
				continue
			}

			assert(grant.weight > 0)
			assert(grant.virtualTime - cpu.floorVirtualTime < GRANT_VIRTUAL_TIME_SPAN)
			ordered_remove(&cpu.grants, idx)
			cpu.floorVirtualTime = grant.virtualTime
			cpu.currentGrant = grant
			intrinsics.atomic_add(&cpu.tlbEpoch, 1)
			spinlock.unlock(&cpu.lock)

			lapic_set_deadline(tscTicksPerMs * GRANT_SLICE_MS)
			run_resume(grant.domain.pml4 | u64(grant.domain.pcid), grant.entry, grant.saveArea)
		}
		spinlock.unlock(&cpu.lock)

		lapic_disable_deadline()
		if info.idleCount == 0 {
			cpu_halt()
		} else {
			assert(u8(idleLevel) < info.idleCount)
			cpu_mwait(info.mwaitHints[idleLevel])
		}
	}
}

grant_preempt :: proc(cpu: ^CpuState, frame: ^InterruptFrame) -> ! {
	grant := &cpu.currentGrant
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)
	assert(!grant.sleepState.asleep)

	if intrinsics.atomic_load(&grant.weight) != 0 {
		domain_switch_cr3(grant.domain)
		user_save_area_store(grant.saveArea, frame)
		kernel_switch_cr3()
	}

	spinlock.lock(&cpu.lock)
	if grant.weight != 0 {
		grant.virtualTime += grant_charge(grant.weight)
		err := grant_enqueue(cpu, grant^)
		print.kensure(err == nil, "grant_preempt: requeue failed")
	}
	cpu.currentGrant = {}
	spinlock.unlock(&cpu.lock)
	run_abort()
}

grant_exit :: proc() -> ! {
	kernel_switch_cr3()
	cpu := gs_read_cpustate()
	domain := cpu.currentGrant.domain
	if domain != nil && intrinsics.atomic_load(&cpu.currentGrant.weight) != 0 {
		spinlock.rw_write_lock(&domain.lock)
		spinlock.lock(&cpu.lock)
		if cpu.currentGrant.weight != 0 do grant_kill_locked(cpu, domain)
		spinlock.unlock(&cpu.lock)
		spinlock.rw_write_unlock(&domain.lock)
	}
	spinlock.lock(&cpu.lock)
	cpu.currentGrant = {}
	spinlock.unlock(&cpu.lock)
	run_abort()
}

syscall_grant_spawn :: proc "contextless" (
	handle: int,
	cpuIdx, saveAreaPtr, weight, entry: u64,
) -> syscalls.GrantError {
	context = gKernelCtx
	spinlock.rw_read_lock(&protDomainPool.rwLock)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock)

	target, targetCpu := grant_syscall_target_DOESNT_LOCK(handle, cpuIdx) or_return
	saveArea := (^userschedule.UserSaveArea)(uintptr(saveAreaPtr))
	return grant_spawn(target, targetCpu, saveArea, entry, weight)
}

syscall_grant_edit :: proc "contextless" (handle: int, cpuIdx, weight: u64) -> syscalls.GrantError {
	context = gKernelCtx
	spinlock.rw_read_lock(&protDomainPool.rwLock)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock)

	target, targetCpu := grant_syscall_target_DOESNT_LOCK(handle, cpuIdx) or_return
	return grant_edit(target, targetCpu, weight)
}

grant_syscall_target_DOESNT_LOCK :: proc(
	handle: int,
	cpuIdx: u64,
) -> (
	target: ^ProtectionDomain,
	targetCpu: ^CpuState,
	err: syscalls.GrantError,
) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)
	if cpuIdx >= u64(len(cpus)) do return nil, nil, .InvalidCpu

	resolved, targetErr := protdomain_resolve_target_DOESNT_LOCK(handle, caller)
	switch targetErr {
	case .None:
	case .InvalidHandle:
		return nil, nil, .InvalidHandle
	case .NoPermission:
		return nil, nil, .NoPermission
	}
	return resolved, &cpus[cpuIdx], .None
}
