package kernel
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "core:encoding/endian"
import "core:mem"
import "pmm"

syscall_contract_create :: proc(handle: int, phys, size, descPtr: u64) -> (err: shared.Error) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)

	if size == 0 do return .InvalidRegion
	upperBound, overflown := intrinsics.overflow_add(phys, size)
	if overflown do return .InvalidRegion

	desc: [1]syscalls.ContractDesc
	if !user_copy_in(caller, desc[:], descPtr) do return .InvalidAddress

	if desc[0].rCount == 0 && desc[0].wCount == 0 do return .InvalidRules
	rRules := contract_rules_copy_in(caller, desc[0].rPtr, desc[0].rCount, false) or_return
	defer if err != .None do delete(rRules)

	wRules := contract_rules_copy_in(caller, desc[0].wPtr, desc[0].wCount, true) or_return
	defer if err != .None do delete(wRules)
	poolGuards := [][]u8 {
		mem.ptr_to_bytes(&protDomainPool),
		mem.slice_to_bytes(protDomainPool.prots[:]),
		mem.slice_to_bytes(protDomainPool.freeSlots[:]),
	}
	spinlock.rw_read_lock(&protDomainPool.rwLock, poolGuards)
	defer spinlock.rw_read_unlock(&protDomainPool.rwLock, poolGuards)

	target := protdomain_resolve_target_NO_LOCK(handle, caller) or_return
	domains_write_lock(caller, target)
	defer domains_write_unlock(caller, target)

	ownerIdx, owned := resource_find_containing(caller.resources[:], phys)
	if !owned do return .NotOwned
	owner := caller.resources[ownerIdx]
	if upperBound > owner.phys + owner.size do return .NotOwned
	if resource_contracted(owner) do return .NotOwned
	if len(wRules) > 0 && .Write not_in owner.flags do return .NoPermission

	if resource_overlaps(target.resources[:], phys, size) do return .InvalidRegion
	if reserve_soa(&target.resources, len(target.resources) + 1) != nil do return .OutOfMemory


	contracted := owner
	contracted.phys, contracted.logical = phys, phys
	contracted.size = size
	contracted.flags = {}
	contracted.contract = new(ContractRules)
	if contracted.contract == nil do return .OutOfMemory
	contracted.contract^ = {
		r = rRules,
		w = wRules,
	}
	_, inserted := resource_insert(&target.resources, contracted)
	assert(inserted)

	memory_underlay_increment(owner.underlay)
	return .None

}

syscall_contract_memory_access :: proc(dst, buf, bufLen, dirRaw: u64) -> (err: shared.Error) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)

	if dirRaw > u64(max(syscalls.ContractAccessDir)) do return .InvalidDir
	dir := syscalls.ContractAccessDir(dirRaw)

	if bufLen == 0 || bufLen > syscalls.CONTRACT_ACCESS_MAX do return .InvalidSize
	if (bufLen == 4 || bufLen == 8) && dst % bufLen != 0 do return .InvalidAddress

	slotBuf: [syscalls.CONTRACT_ACCESS_MAX]byte
	#assert(size_of(slotBuf) < 2 * mem.Kilobyte)
	slot := slotBuf[:bufLen]
	if dir == .Write && !user_copy_in(caller, slot, buf) do return .InvalidAddress
	{
		domain_read_lock(caller)

		idx, found := resource_find_containing(caller.resources[:], dst)
		if !found do return .NotContracted
		res := caller.resources[idx]
		if !resource_contracted(res) do return .NotContracted
		end, overflow := intrinsics.overflow_add(dst, bufLen)
		if overflow || end > res.phys + res.size do return .OutOfBounds
		rules := res.contract.w if dir == .Write else res.contract.r

		if len(rules) == 0 do return .Denied
		if !contract_run_NO_LOCK(rules, slot, dst - res.phys, caller) do return .Denied

		ptr := pmm.phys_to_ptr(dst)
		switch dir {
		case .Write:
			switch bufLen {
			case 4:
				v, ok := endian.get_u32(slot, .Little)
				assert(ok)
				intrinsics.volatile_store((^u32)(ptr), v)
			case 8:
				v, ok := endian.get_u64(slot, .Little)
				assert(ok)
				intrinsics.volatile_store((^u64)(ptr), v)
			case:
				mem.copy(ptr, raw_data(slot), int(bufLen))
			}
		case .Read:
			switch bufLen {
			case 4:
				ok := endian.put_u32(slot, .Little, intrinsics.volatile_load((^u32)(ptr)))
				assert(ok)
			case 8:
				ok := endian.put_u64(slot, .Little, intrinsics.volatile_load((^u64)(ptr)))
				assert(ok)
			case:
				mem.copy(raw_data(slot), ptr, int(bufLen))
			}
		}

	}
	if dir == .Read && !user_copy_out(caller, buf, slot) do return .InvalidAddress
	return .None
}

contract_rules_copy_in :: proc(
	domain: ^ProtectionDomain,
	ptr, count: u64,
	isWrite: bool,
) -> (
	rules: []syscalls.ContractRule,
	err: shared.Error,
) {
	if count == 0 do return nil, .None
	_, overflown := intrinsics.overflow_mul(count, size_of(syscalls.ContractRule))

	if overflown do return nil, .InvalidAddress
	aErr: mem.Allocator_Error
	rules, aErr = make([]syscalls.ContractRule, count)
	if aErr != .None do return nil, .OutOfMemory
	defer if err != .None do delete(rules)

	if !user_copy_in(domain, rules, ptr) do return nil, .InvalidAddress
	if !contract_validate(rules, isWrite) do return nil, .InvalidRules
	return rules, .None
}
contract_validate :: proc(rules: []syscalls.ContractRule, isWrite: bool) -> bool {
	for rule, pc in rules {
		switch rule.op {
		case .Add, .Sub, .Shl, .Shr, .And:
			if rule.a >= 8 || rule.b >= 8 || rule.imm != 0 do return false
		case .Imm:
			if rule.a >= 8 || rule.b != 0 do return false
		case .Load8, .Load16, .Load32, .Load64, .Store64:
			if !isWrite do return false
			if rule.a >= 8 || rule.b != 0 do return false
			if rule.imm >= syscalls.CONTRACT_ACCESS_MAX do return false
		case .Jeq, .Jne, .Jlt, .Jge:
			if rule.a >= 8 || rule.b >= 8 do return false
			if rule.imm <= u64(pc) || rule.imm > u64(len(rules)) do return false
		case .Accept:
			if rule.a != 0 || rule.b != 0 || rule.imm != 0 do return false
		case .HasPermR, .HasPermW:
			if rule.a >= 8 || rule.b >= 8 || rule.imm != 0 do return false
		case .Copy, .ListR, .ListW:
			return false
		case:
			return false
		}
	}
	return true
}

contract_run_NO_LOCK :: proc(
	rules: []syscalls.ContractRule,
	slot: []u8,
	dstOffset: u64,
	domain: ^ProtectionDomain,
) -> bool {
	assert(len(slot) <= syscalls.CONTRACT_ACCESS_MAX)
	r: [8]u64
	r[0] = dstOffset
	r[1] = u64(len(slot))

	for pc := 0; pc < len(rules); {
		rule := rules[pc]
		assert(rule.a < 8 && rule.b < 8)
		next := pc + 1
		switch rule.op {
		case .Load8:
			if rule.imm + 1 > u64(len(slot)) do return false
			r[rule.a] = u64(slot[rule.imm])
		case .Load16:
			if rule.imm + 2 > u64(len(slot)) do return false
			v, ok := endian.get_u16(slot[rule.imm:], .Little)
			assert(ok)
			r[rule.a] = u64(v)
		case .Load32:
			if rule.imm + 4 > u64(len(slot)) do return false
			v, ok := endian.get_u32(slot[rule.imm:], .Little)
			assert(ok)
			r[rule.a] = u64(v)
		case .Load64:
			if rule.imm + 8 > u64(len(slot)) do return false
			v, ok := endian.get_u64(slot[rule.imm:], .Little)
			assert(ok)
			r[rule.a] = v
		case .Store64:
			if rule.imm + 8 > u64(len(slot)) do return false
			ok := endian.put_u64(slot[rule.imm:], .Little, r[rule.a])
			assert(ok)
		case .Imm:
			r[rule.a] = rule.imm
		case .Add:
			overflown: bool
			r[rule.a], overflown = intrinsics.overflow_add(r[rule.a], r[rule.b])
			if overflown do return false
		case .Sub:
			if r[rule.b] > r[rule.a] do return false
			r[rule.a] -= r[rule.b]
		case .Shl:
			if r[rule.b] >= 64 || (r[rule.a] << r[rule.b]) >> r[rule.b] != r[rule.a] do return false
			r[rule.a] <<= r[rule.b]
		case .Shr:
			if r[rule.b] >= 64 do return false
			r[rule.a] >>= r[rule.b]
		case .And:
			r[rule.a] &= r[rule.b]
		case .Jeq:
			if r[rule.a] == r[rule.b] do next = int(rule.imm)
		case .Jne:
			if r[rule.a] != r[rule.b] do next = int(rule.imm)
		case .Jlt:
			if r[rule.a] < r[rule.b] do next = int(rule.imm)
		case .Jge:
			if r[rule.a] >= r[rule.b] do next = int(rule.imm)

		case .HasPermR, .HasPermW:
			if !user_range_accessible_NO_LOCK(domain, r[rule.a], r[rule.b], rule.op == .HasPermW) do return false
		case .Accept:
			return true
		case .Copy, .ListR, .ListW:
			unreachable()
		case:
			unreachable()
		}
		assert(next > pc)
		pc = next
	}
	return false
}

contract_rules_free :: proc(c: ^ContractRules) {
	if c == nil do return
	delete(c.r)
	delete(c.w)
	free(c)
}
