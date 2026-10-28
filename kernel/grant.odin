package kernel

import ah "../asm_helpers"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "core:container/bit_array"
import "core:mem"
import "pmm"
import "print"

GRANT_SLICE_MS :: 5
GRANT_VIRTUAL_TIME_SPAN :: u64(1) << 62
CPU_GRANT_STARTING_CAPACITY :: 128
SLEEPER_POLLS_PER_MS :: 10

#assert(userschedule.SCHED_WEIGHT_TOTAL <= u64(1) << 20)
#assert(size_of(userschedule.UserSaveArea) <= shared.PAGE_SIZE)
#assert(u64(syscalls.SchedulerEnterReason.Fault) == 1)
#assert(u64(syscalls.SchedulerEnterReason.Resume) == 2)

IdleLevel :: distinct u8

CpuGrant :: struct {
	saveArea:         ^userschedule.UserSaveArea,
	saveAreaUnderlay: ^MemoryUnderlay,
	entry:            u64,
	weight:           u64,
	domain:           ^ProtectionDomain,
	virtualTime:      u64,
	idleLevel:        IdleLevel,
}

WaitTarget :: struct {
	addr, oldValue, deadline: u64,
}

SleepingGrant :: struct {
	using grant: CpuGrant,
	using wait:  WaitTarget,
}

SyscallFrame :: struct {
	r15, r14, r13, r12, rbp, rbx, rflags, rip: u64,
}
#assert(size_of(SyscallFrame) == 64)

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_read_cpustate :: proc() -> ^CpuState ---
		run_resume :: proc(targetCr3: u64, entry: u64, area: ^userschedule.UserSaveArea, reason: syscalls.SchedulerEnterReason) -> ! ---
		run_abort :: proc() -> ! ---
		user_save_area_store :: proc(area: ^userschedule.UserSaveArea, frame: ^InterruptFrame) ---
		save_area_xsave :: proc(area: ^userschedule.UserSaveArea) ---
		cpu_cli :: proc() ---
		cpu_monitor :: proc(address: rawptr) ---
		cpu_mwait :: proc(hint: u32) ---
		cpu_halt :: proc() ---
	}
} else {
	@(thread_local)
	testCpu: ^CpuState

	gs_read_cpustate :: proc "contextless" () -> ^CpuState {return testCpu}
	run_resume :: proc "contextless" (
		targetCr3: u64,
		entry: u64,
		area: ^userschedule.UserSaveArea,
		reason: syscalls.SchedulerEnterReason,
	) -> ! {for {}}
	run_abort :: proc "contextless" () -> ! {for {}}
	user_save_area_store :: proc "contextless" (
		area: ^userschedule.UserSaveArea,
		frame: ^InterruptFrame,
	) {}
	save_area_xsave :: proc "contextless" (area: ^userschedule.UserSaveArea) {}
	cpu_cli :: proc "contextless" () {}
	cpu_monitor :: proc "contextless" (address: rawptr) {}
	cpu_mwait :: proc "contextless" (hint: u32) {}
	cpu_halt :: proc "contextless" () {}
}

grant_charge :: proc "contextless" (weight: u64) -> u64 {
	return tscTicksPerMs * GRANT_SLICE_MS * userschedule.SCHED_WEIGHT_TOTAL / weight
}

cpu_kick :: proc "contextless" (cpu: ^CpuState) {
	if cpu != gs_read_cpustate() {
		send_ipi(cpu_info(cpu).apicId, VECTOR_APIC_IPI)
		return
	}
	if cpu.currentGrant.domain != nil && !cpu.sliceArmed do grant_arm_slice(cpu)
}

grant_arm_slice :: proc "contextless" (cpu: ^CpuState) {
	lapic_set_deadline(tscTicksPerMs * GRANT_SLICE_MS)
	cpu.sliceArmed = true
}

grant_arm_slice_if_contended :: proc "contextless" (cpu: ^CpuState) {
	if cpu.sliceArmed || cpu.currentGrant.domain == nil do return
	spinlock.lock(&cpu.lock)
	waiting := len(cpu.grants) > 0
	spinlock.unlock(&cpu.lock)
	if waiting do grant_arm_slice(cpu)
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

grant_find_locked :: proc(
	cpu: ^CpuState,
	domain: ^ProtectionDomain,
) -> (
	grant: ^CpuGrant,
	asleep: bool,
) {
	if cpu.currentGrant.domain == domain && cpu.currentGrant.weight > 0 do return &cpu.currentGrant, false
	for &queued in cpu.grants {
		if queued.domain == domain do return &queued, false
	}
	for &sleeper in cpu.sleepers {
		if sleeper.domain == domain do return &sleeper.grant, true
	}
	return nil, false
}

grant_kill_locked :: proc(cpu: ^CpuState, domain: ^ProtectionDomain) {
	grant, asleep := grant_find_locked(cpu, domain)
	assert(grant != nil)
	killed := grant^
	assert(killed.weight > 0)

	switch {
	case grant == &cpu.currentGrant:
		intrinsics.atomic_store(&grant.weight, 0)
		cpu_kick(cpu)
	case asleep:
		sleeper := container_of(grant, SleepingGrant, "grant")
		unordered_remove(&cpu.sleepers, mem.ptr_sub(sleeper, &cpu.sleepers[0]))
		memory_underlay_release(killed.saveAreaUnderlay)
	case:
		ordered_remove(&cpu.grants, mem.ptr_sub(grant, &cpu.grants[0]))
		memory_underlay_release(killed.saveAreaUnderlay)
	}

	domain.weightFree += killed.weight
	assert(domain.weightFree <= userschedule.SCHED_WEIGHT_TOTAL)
	unset := bit_array.unset(&domain.grantCpus, cpu_index(cpu))
	assert(unset)

	info := cpu_info(cpu)
	assert(info.grantedWeight >= killed.weight)
	intrinsics.atomic_store(&info.grantedWeight, info.grantedWeight - killed.weight)
}

grant_spawn :: proc(
	domain: ^ProtectionDomain,
	cpu: ^CpuState,
	saveArea: ^userschedule.UserSaveArea,
	entry: u64,
	weight: u64,
) -> shared.Error {
	assert(domain != nil)
	assert(cpu != nil)

	if saveArea == nil || uintptr(saveArea) % align_of(userschedule.UserSaveArea) != 0 do return .InvalidSaveArea
	if entry == 0 || entry >= USER_ADDR_END do return .InvalidEntry

	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	if bit_array.get(&domain.grantCpus, cpu_index(cpu)) do return .AlreadyOnCpu
	if weight == 0 || weight > domain.weightFree do return .InsufficientWeight
	saveAreaAddr := u64(uintptr(saveArea))
	if !user_range_accessible(domain, saveAreaAddr, size_of(userschedule.UserSaveArea), true) do return .InvalidSaveArea
	ownerIdx, owned := resource_find_containing(domain.resources[:], saveAreaAddr)
	assert(owned)
	ownerEnd := domain.resources.phys[ownerIdx] + domain.resources.size[ownerIdx]
	if saveAreaAddr + size_of(userschedule.UserSaveArea) > ownerEnd do return .InvalidSaveArea
	saveAreaUnderlay := domain.resources.underlay[ownerIdx]

	info := cpu_info(cpu)
	if !intrinsics.atomic_load(&info.online) do return .InvalidCpu

	{
		spinlock.lock(&cpu.lock)
		defer spinlock.unlock(&cpu.lock)

		grant := CpuGrant {
			saveArea         = saveArea,
			saveAreaUnderlay = saveAreaUnderlay,
			entry            = entry,
			weight           = weight,
			domain           = domain,
			virtualTime      = cpu.floorVirtualTime + grant_charge(weight),
			idleLevel        = IdleLevel(max(info.idleCount, 1) - 1),
		}
		if grant_enqueue(cpu, grant) != nil do return .OutOfMemory
		intrinsics.atomic_store(&info.grantedWeight, info.grantedWeight + weight)
	}

	memory_underlay_increment(saveAreaUnderlay)
	domain.weightFree -= weight
	set := bit_array.set(&domain.grantCpus, cpu_index(cpu))
	assert(set)
	cpu_kick(cpu)
	return .None
}

grant_edit :: proc(domain: ^ProtectionDomain, cpu: ^CpuState, weight: u64) -> shared.Error {
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

	grant, _ := grant_find_locked(cpu, domain)
	assert(grant != nil)
	assert(grant.weight + domain.weightFree <= userschedule.SCHED_WEIGHT_TOTAL)
	if weight > grant.weight + domain.weightFree do return .InsufficientWeight

	domain.weightFree = domain.weightFree + grant.weight - weight
	info := cpu_info(cpu)
	intrinsics.atomic_store(&info.grantedWeight, info.grantedWeight + weight - grant.weight)
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
	grant_drop_current(cpu)
}

grant_drop_current :: proc(cpu: ^CpuState) {
	spinlock.lock(&cpu.lock)
	dropped := cpu.currentGrant
	cpu.currentGrant = {}
	spinlock.unlock(&cpu.lock)
	assert(dropped.weight == 0)
	if dropped.saveAreaUnderlay != nil do memory_underlay_release(dropped.saveAreaUnderlay)
}

@(export)
grant_loop :: proc "c" () -> ! {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	assert(cpu.currentGrant.domain == nil)
	info := cpu_info(cpu)

	for {
		cpu_cli()
		if next, contended, ok := grant_pop(cpu); ok do grant_run(cpu, next, contended)
		cpu_sleep(cpu)
	}
}

grant_pop :: proc(cpu: ^CpuState) -> (next: CpuGrant, contended, ok: bool) {
	spinlock.lock(&cpu.lock)
	defer spinlock.unlock(&cpu.lock)
	grant_wake_locked(cpu)
	if len(cpu.grants) == 0 do return {}, false, false
	next = pop(&cpu.grants)
	assert(next.weight > 0)
	assert(next.virtualTime - cpu.floorVirtualTime < GRANT_VIRTUAL_TIME_SPAN)
	cpu.floorVirtualTime = next.virtualTime
	cpu.currentGrant = next
	return next, len(cpu.grants) > 0 || len(cpu.sleepers) > 0, true
}

grant_run :: proc(cpu: ^CpuState, next: CpuGrant, contended: bool) -> ! {
	intrinsics.atomic_thread_fence(.Seq_Cst)
	if contended {
		grant_arm_slice(cpu)
	} else {
		lapic_disable_deadline()
		cpu.sliceArmed = false
	}
	run_resume(domain_cr3(cpu, next.domain), next.entry, next.saveArea, .Resume)
}

cpu_sleep :: proc(cpu: ^CpuState) {
	info := cpu_info(cpu)
	watched, watchedOld, deadline, idleLevel := sleep_target(cpu)
	cpu.sliceArmed = false
	if deadline == max(u64) {
		lapic_disable_deadline()
	} else {
		lapic_set_deadline_at(deadline)
	}
	if info.idleCount == 0 {
		cpu_halt()
		return
	}
	cpu_monitor(watched)
	if intrinsics.atomic_load(watched) != watchedOld do return
	assert(u8(idleLevel) < info.idleCount)
	cpu_mwait(info.mwaitHints[idleLevel])
}

sleep_target :: proc(
	cpu: ^CpuState,
) -> (
	watched: ^u64,
	watchedOld, deadline: u64,
	idleLevel: IdleLevel,
) {
	info := cpu_info(cpu)
	spinlock.lock(&cpu.lock)
	defer spinlock.unlock(&cpu.lock)
	watched = &info.grantedWeight
	watchedOld = intrinsics.atomic_load(watched)
	deadline = max(u64)
	idleLevel = IdleLevel(max(info.idleCount, 1) - 1)
	for sleeper in cpu.sleepers {
		deadline = min(deadline, sleeper.deadline)
		idleLevel = min(idleLevel, sleeper.idleLevel)
	}
	if len(cpu.sleepers) > 0 {
		watched = (^u64)(pmm.phys_to_ptr(cpu.sleepers[0].addr))
		watchedOld = cpu.sleepers[0].oldValue
	}
	if len(cpu.sleepers) > 1 do deadline = min(deadline, ah.rdtsc_asm() + tscTicksPerMs / SLEEPER_POLLS_PER_MS)
	return
}

grant_wake_locked :: proc(cpu: ^CpuState) {
	now := ah.rdtsc_asm()
	for idx := len(cpu.sleepers) - 1; idx >= 0; idx -= 1 {
		sleeper := cpu.sleepers[idx]
		changed :=
			intrinsics.atomic_load((^u64)(pmm.phys_to_ptr(sleeper.addr))) != sleeper.oldValue
		if !changed && now < sleeper.deadline do continue
		saveArea := (^userschedule.UserSaveArea)(pmm.phys_to_ptr(u64(uintptr(sleeper.saveArea))))
		result := shared.Error.None if changed else shared.Error.Timeout
		saveArea.rax = u64(result)
		grant := sleeper.grant
		if i64(grant.virtualTime - cpu.floorVirtualTime) < 0 do grant.virtualTime = cpu.floorVirtualTime
		unordered_remove(&cpu.sleepers, idx)
		err := grant_enqueue(cpu, grant)
		print.kensure(err == nil, "grant_wake_locked: requeue failed")
	}
}

grant_preempt :: proc(cpu: ^CpuState, frame: ^InterruptFrame) -> ! {
	grant := &cpu.currentGrant
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)
	if intrinsics.atomic_load(&grant.weight) != 0 {
		saveArea := (^userschedule.UserSaveArea)(pmm.phys_to_ptr(u64(uintptr(grant.saveArea))))
		user_save_area_store(saveArea, frame)
	}
	grant_switch_out(cpu, nil)
}
grant_fault :: proc(cpu: ^CpuState, frame: ^InterruptFrame) -> ! {
	grant := &cpu.currentGrant
	assert(grant.domain != nil)
	assert(grant.saveArea != nil)
	saveArea := (^userschedule.UserSaveArea)(pmm.phys_to_ptr(u64(uintptr(grant.saveArea))))
	if intrinsics.atomic_load(&grant.weight) == 0 || saveArea.control.restoring {
		grant_exit()
	}
	user_save_area_store(saveArea, frame)
	saveArea.faultVector = frame.interruptNumber
	saveArea.faultError = frame.error_code
	saveArea.faultAddress = ah.read_cr2()
	run_resume(domain_cr3(cpu, grant.domain), grant.entry, grant.saveArea, .Fault)
}
grant_switch_out :: proc(cpu: ^CpuState, wait: Maybe(WaitTarget)) -> ! {
	kernel_switch_cr3()
	released: ^MemoryUnderlay
	{
		spinlock.lock(&cpu.lock)
		defer spinlock.unlock(&cpu.lock)
		grant := cpu.currentGrant
		killed := grant.weight == 0
		switch {
		case killed:
			released = grant.saveAreaUnderlay
		case wait != nil:
			grant.virtualTime += grant_charge(grant.weight)
			_, err := append(&cpu.sleepers, SleepingGrant{grant = grant, wait = wait.?})
			print.kensure(err == nil, "grant_switch_out: sleep failed")
		case:
			grant.virtualTime += grant_charge(grant.weight)
			err := grant_enqueue(cpu, grant)
			print.kensure(err == nil, "grant_switch_out: requeue failed")
		}
		cpu.currentGrant = {}
	}
	if released != nil do memory_underlay_release(released)
	run_abort()
}

syscall_wait_on :: proc(addr, oldValue, deadline: u64) -> shared.Error {
	cpu := gs_read_cpustate()
	grant := &cpu.currentGrant
	domain := grant.domain
	assert(domain != nil)
	assert(grant.saveArea != nil)

	if addr % 8 != 0 do return .InvalidAddress
	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)
		if !user_range_accessible(domain, addr, 8, false) do return .InvalidAddress
	}
	if intrinsics.atomic_load((^u64)(pmm.phys_to_ptr(addr))) != oldValue do return .None
	if ah.rdtsc_asm() >= deadline do return .Timeout

	saveArea := (^userschedule.UserSaveArea)(pmm.phys_to_ptr(u64(uintptr(grant.saveArea))))
	if saveArea.control.restoring do return .InvalidSaveArea
	syscall_save_area_store(cpu, saveArea)
	grant_switch_out(cpu, WaitTarget{addr = addr, oldValue = oldValue, deadline = deadline})
}

syscall_save_area_store :: proc(cpu: ^CpuState, saveArea: ^userschedule.UserSaveArea) {
	assert(!saveArea.control.restoring)
	frame := (^SyscallFrame)(uintptr(cpu.kernelStackTop) - size_of(SyscallFrame))
	saveArea.rbx = frame.rbx
	saveArea.rbp = frame.rbp
	saveArea.r12 = frame.r12
	saveArea.r13 = frame.r13
	saveArea.r14 = frame.r14
	saveArea.r15 = frame.r15
	saveArea.rip = frame.rip
	saveArea.rflags = frame.rflags
	saveArea.rsp = cpu.userSyscallRsp
	saveArea.gsBase = ah.rdmsr_asm(IA32_KERNEL_GS_BASE)
	save_area_xsave(saveArea)
	saveArea.control.restoring = true
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
	grant_drop_current(cpu)
	run_abort()
}

syscall_grant_spawn :: proc(
	handle: int,
	cpuIdx, saveAreaPtr, weight, entry: u64,
) -> shared.Error {
	spinlock.rw_read_lock(&protDomainPool.rwLock)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock)

	target, targetCpu := grant_syscall_target_DOESNT_LOCK(handle, cpuIdx) or_return
	saveArea := (^userschedule.UserSaveArea)(uintptr(saveAreaPtr))
	return grant_spawn(target, targetCpu, saveArea, entry, weight)
}

syscall_grant_edit :: proc(handle: int, cpuIdx, weight: u64) -> shared.Error {
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
	err: shared.Error,
) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)
	if cpuIdx >= u64(len(cpus)) do return nil, nil, .InvalidCpu

	target = protdomain_resolve_target_DOESNT_LOCK(handle, caller) or_return
	return target, &cpus[cpuIdx], .None
}
