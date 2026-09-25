package kernel
import "../lib/spinlock"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
syscall_grant_spawn :: proc "contextless" (
	handle: int,
	cpuIdx, saveAreaPtr, weight: u64,
) -> (
	err: syscalls.GrantError,
) {
	context = gKernelCtx
	spinlock.rw_read_lock(&protDomainPool.rwLock)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock)

	target, targetCpu := grant_syscall_target_DOESNT_LOCK(handle, cpuIdx) or_return
	return grant_spawn(
		target,
		targetCpu,
		(^userschedule.UserSaveArea)(uintptr(saveAreaPtr)),
		weight,
	)
}

syscall_grant_edit :: proc "contextless" (
	handle: int,
	cpuIdx, weight: u64,
) -> (
	err: syscalls.GrantError,
) {
	context = gKernelCtx
	{
		spinlock.rw_read_lock(&protDomainPool.rwLock)
		defer spinlock.rw_read_unlock(&protDomainPool.rwLock)

		target, targetCpu := grant_syscall_target_DOESNT_LOCK(handle, cpuIdx) or_return
		err = grant_edit(target, targetCpu, weight)
	}

	cpu := gs_read_cpustate()
	assert(cpu != nil)
	if intrinsics.atomic_load(&cpu.currentGrant.weight) == 0 {
		grant_stop_current(cpu)
		run_abort()
	}
	return err
}

grant_syscall_target_DOESNT_LOCK :: proc(
	handle: int,
	cpuIdx: u64,
) -> (
	target: ^ProtectionDomain,
	targetCpu: ^CpuState,
	err: syscalls.GrantError,
) {
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.currentGrant.domain == nil do return nil, nil, .NoPermission
	if cpuIdx >= u64(len(cpus)) do return nil, nil, .InvalidCpu

	resolved, targetErr := protdomain_resolve_target_DOESNT_LOCK(handle, cpu.currentGrant.domain)
	switch targetErr {
	case .None:
	case .InvalidHandle:
		return nil, nil, .InvalidHandle
	case .NoPermission:
		return nil, nil, .NoPermission
	}
	return resolved, &cpus[cpuIdx], .None
}
