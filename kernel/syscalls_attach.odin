package kernel

import "../lib/lmem"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"


syscall_attachment_set :: proc "contextless" (
	handle, entryRip: u64,
) -> syscalls.AttachmentSetError {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission
	}
	if entryRip == 0 do return .InvalidEntry

	target := protdomain_resolve_target(handle, cpu.rrCurrent.domain)
	if target == nil do return .InvalidHandle

	spinlock.rw_write_lock(&target.lock)
	defer spinlock.rw_write_unlock(&target.lock)
	target.attachmentEntry = entryRip
	return .None
}

syscall_attachment_remove :: proc "contextless" (handle: u64) -> syscalls.AttachmentRemoveError {
	context = gKernelCtx
	cpu := gs_read_cpustate()
	if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
		return .NoPermission
	}

	target := protdomain_resolve_target(handle, cpu.rrCurrent.domain)
	if target == nil do return .InvalidHandle

	spinlock.rw_write_lock(&target.lock)
	defer spinlock.rw_write_unlock(&target.lock)
	target.attachmentEntry = 0
	return .None
}
