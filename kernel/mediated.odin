package kernel

import "../lib/lmem"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "core:mem"
import "pmm"


KERNEL_MMIO_FLAGS :: lmem.PageFlags{.Present, .Write, .PWT, .PCD, .NX}


syscall_mediated_create :: proc "contextless" (
	rulesPtr, count: u64,
) -> (
	err: syscalls.MediatedError,
) {
	context = gKernelCtx
	domain := gs_read_cpustate().currentGrant.domain
	assert(domain != nil)
	if domain == nil do return .KernelErr

	if count == 0 || count > syscalls.MEDIATED_MAX_RULES do return .InvalidCount

	rules, aErr := make([]syscalls.MediatedRule, int(count))
	if aErr != nil do return .OutOfMemory
	defer if err != {} do delete(rules)

	{
		spinlock.rw_read_lock(&domain.lock)
		defer spinlock.rw_read_unlock(&domain.lock)

		ruleBytes := count * size_of(syscalls.MediatedRule)

		if !user_range_accessible(domain, u64(uintptr(raw_data(rules))), ruleBytes, false) do return .InvalidRule
		mem.copy(raw_data(rules), rawptr(uintptr(rulesPtr)), int(ruleBytes))
	}

	for rule, i in rules {
		if rule.size == 0 || rule.flags == {} do return .InvalidRule
		if rule.flags - syscalls.MEDIATED_FLAGS_ALL != {} do return .InvalidRule
		if _, overflow := intrinsics.overflow_add(rule.phys, rule.size); overflow do return .InvalidRule
		if i > 0 && rule.phys < rules[i - 1].phys + rules[i - 1].size do return .InvalidRule
	}
	defer if err != {} do tlb_wait_domain_flushed(domain)
	spinlock.rw_write_lock(&domain.lock)
	defer spinlock.rw_write_unlock(&domain.lock)

	ownerIdx, owned := resource_find_containing(domain.resources[:], rules[0].phys)
	if !owned do return .NotOwned
	owner := domain.resources[ownerIdx]
	last := rules[len(rules) - 1]

	if last.phys + last.size > owner.phys + owner.size do return .NotOwned
	if .Write not_in owner.flags do return .NotOwned
	if len(owner.rules) != 0 do return .NotOwned

	{
		spinlock.lock(&memoryUnderlaysLock)
		defer spinlock.unlock(&memoryUnderlaysLock)
		if owner.underlay.refs != 1 do return .Shared
	}

	domain.resources.rules[ownerIdx] = rules
	owner.rules = rules
}
