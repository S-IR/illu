package kernel
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "base:intrinsics"
import "core:encoding/endian"
import "core:mem"
import "pmm"
RingSlotState :: enum u8 {
	Free,
	InFlight,
	Done,
}

RingSlot :: struct {
	owner:  ^ProtectionDomain,
	state:  RingSlotState,
	status: u16,
}

Ring :: struct {
	lock:          spinlock.Spinlock,
	authorityPtr:  ^byte,
	sq:            syscalls.RingSq,
	cq:            syscalls.RingCq,
	authoritySize: u64,
	rules:         []syscalls.ContractRule,
	underlays:     [4]^MemoryUnderlay,
	mutable:       struct {
		sqTail:     u64,
		cqHead:     u64,
		cqPhase:    u8,
		inFlight:   u64,
		slots:      []RingSlot,
		freeTokens: []u16,
		freeCount:  u64,
	},
}
RingPool :: struct {
	rwLock:    spinlock.RWLock,
	rings:     [dynamic]^Ring,
	freeSlots: [dynamic]int,
}

ring_pool_guards :: proc "contextless" () -> [3][]byte {
	return {
		mem.ptr_to_bytes(&kernelState.ringPool),
		mem.slice_to_bytes(kernelState.ringPool.rings[:]),
		mem.slice_to_bytes(kernelState.ringPool.freeSlots[:]),
	}
}

@(deferred_out = ring_pool_read_unlock)
ring_pool_read_lock :: proc "contextless" () -> [3][]byte {
	guards := ring_pool_guards()
	spinlock.rw_read_lock(&kernelState.ringPool.rwLock, guards[:])
	return guards
}

ring_pool_read_unlock :: proc "contextless" (g: [3][]byte) {
	guards := g
	spinlock.rw_read_unlock(&kernelState.ringPool.rwLock, guards[:])
}

@(deferred_out = ring_pool_write_unlock)
ring_pool_write_lock :: proc "contextless" () -> [3][]byte {
	guards := ring_pool_guards()
	spinlock.rw_write_lock(&kernelState.ringPool.rwLock, guards[:])
	return guards
}

ring_pool_write_unlock :: proc "contextless" (g: [3][]byte) {
	guards := g
	spinlock.rw_write_unlock(&kernelState.ringPool.rwLock, guards[:])
}

ring_guards :: proc "contextless" (r: ^Ring) -> [3][]byte {
	return {
		mem.ptr_to_bytes(&r.mutable),
		mem.slice_to_bytes(r.mutable.slots),
		mem.slice_to_bytes(r.mutable.freeTokens),
	}
}

@(deferred_out = ring_unlock)
ring_lock :: proc "contextless" (r: ^Ring) -> (^Ring, [3][]byte) {
	guards := ring_guards(r)
	spinlock.lock(&r.lock, guards[:])
	return r, guards
}

ring_unlock :: proc "contextless" (r: ^Ring, g: [3][]byte) {
	guards := g
	spinlock.unlock(&r.lock, guards[:])
}


syscall_ring_create :: proc(descPtr: u64) -> (handle: int, err: shared.Error) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)

	rd: syscalls.RingDesc
	if !user_copy_in(caller, mem.ptr_to_bytes(&rd), descPtr) do return 0, .InvalidAddress

	if rd.sq.depth < 2 || rd.sq.depth > 1 << 16 do return 0, .InvalidRing
	if rd.cq.depth < 2 || rd.cq.depth > 1 << 16 do return 0, .InvalidRing
	if rd.sq.entrySize == 0 || rd.sq.entrySize > syscalls.CONTRACT_ACCESS_MAX do return 0, .InvalidRing
	if rd.cq.entrySize == 0 do return 0, .InvalidRing
	if !field_fits(rd.sq.tokenOffset, 2, rd.sq.entrySize) do return 0, .InvalidRing
	if !field_fits(rd.cq.tokenOffset, 2, rd.cq.entrySize) do return 0, .InvalidRing
	if !field_fits(rd.cq.statusOffset, 2, rd.cq.entrySize) do return 0, .InvalidRing
	if !field_fits(rd.cq.phaseOffset, 1, rd.cq.entrySize) do return 0, .InvalidRing
	if rd.cq.phaseBit >= 8 do return 0, .InvalidRing
	if rd.sq.doorbell % 4 != 0 || rd.cq.doorbell % 4 != 0 do return 0, .InvalidRing
	if rd.authoritySize == 0 || rd.authoritySize > rd.sq.depth - 1 do return 0, .InvalidRing
	if rd.cq.phys % 8 != 0 || rd.cq.entrySize % 8 != 0 do return 0, .InvalidRing

	sqBytes, sqOverflow := intrinsics.overflow_mul(rd.sq.depth, rd.sq.entrySize)
	cqBytes, cqOverflow := intrinsics.overflow_mul(rd.cq.depth, rd.cq.entrySize)
	if sqOverflow || cqOverflow do return 0, .InvalidRing

	rules := contract_rules_copy_in(caller, rd.rulesPtr, rd.rulesCount, true) or_return
	if len(rules) == 0 do return 0, .InvalidRules
	defer if err != .None do delete(rules)


	underlays: [4]^MemoryUnderlay
	{
		domain_read_lock(caller)


		if !user_range_accessible_NO_LOCK(caller, rd.authorityPtr, rd.authoritySize, true) do return 0, .NoPermission


		Range :: struct {
			phys, size: u64,
		}
		ranges := [4]Range {
			{rd.sq.phys, sqBytes},
			{rd.cq.phys, cqBytes},
			{rd.sq.doorbell, 4},
			{rd.cq.doorbell, 4},
		}

		for r, i in ranges {
			idx, ok := resource_find_containing(caller.resources[:], r.phys)
			if !ok do return 0, .NotOwned
			res := caller.resources[idx]
			end, overflow := intrinsics.overflow_add(r.phys, r.size)
			if overflow || end > res.phys + res.size do return 0, .NotOwned
			if resource_contracted(res) do return 0, .NotOwned
			if .Write not_in res.flags do return 0, .NoPermission
			underlays[i] = res.underlay
		}
		for a, i in ranges do for b in ranges[i + 1:] {
			if a.phys < b.phys + b.size && b.phys < a.phys + a.size do return 0, .InvalidRing
		}
		for u in underlays do memory_underlay_increment(u)
	}
	defer if err != .None do for u in underlays do memory_underlay_release(u)

	ring, aErr := new(Ring); if aErr != .None do return 0, .OutOfMemory
	defer if err != .None do free(ring)

	slots: []RingSlot
	slots, aErr = make([]RingSlot, rd.sq.depth); if aErr != nil do return 0, .OutOfMemory
	defer if err != .None do delete(slots)

	freeTokens: []u16
	freeTokens, aErr = make([]u16, rd.sq.depth); if aErr != nil do return 0, .OutOfMemory
	defer if err != .None do delete(freeTokens)
	for &token, i in freeTokens do token = u16(i)

	ring.authorityPtr = (^byte)(uintptr(rd.authorityPtr))
	ring.sq = rd.sq
	ring.cq = rd.cq
	ring.authoritySize = rd.authoritySize
	ring.rules = rules
	ring.underlays = underlays
	ring.mutable.slots = slots
	ring.mutable.freeTokens = freeTokens
	ring.mutable.freeCount = rd.sq.depth
	ring.mutable.cqPhase = 1

	ring_pool_write_lock()


	if len(kernelState.ringPool.freeSlots) > 0 {
		idx := pop(&kernelState.ringPool.freeSlots)
		assert(kernelState.ringPool.rings[idx] == nil)
		kernelState.ringPool.rings[idx] = ring
		return idx, .None
	}
	_, aErr = append(&kernelState.ringPool.rings, ring); if aErr != nil do return 0, .OutOfMemory
	return len(kernelState.ringPool.rings) - 1, .None
}
field_fits :: proc(offset, width, size: u64) -> bool {
	return size >= width && offset <= size - width
}
syscall_ring_submit :: proc(
	handle: int,
	entriesPtr, n, tokensOutPtr: u64,
) -> (
	accepted: u64,
	err: shared.Error,
) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)

	if n == 0 do return 0, .InvalidSize

	ring_pool_read_lock()

	domain_read_lock(caller)

	ring, cap := ring_resolve_NO_LOCK(handle, caller) or_return
	if n > ring.sq.depth do return 0, .InvalidSize

	total, overflow := intrinsics.overflow_mul(n, ring.sq.entrySize)
	_, wrap := intrinsics.overflow_add(entriesPtr, total)
	if overflow || wrap do return 0, .InvalidAddress
	if !user_mapped_range_accessible_NO_LOCK(caller, tokensOutPtr, n * size_of(u16), true) do return 0, .InvalidAddress

	ring_lock(ring)

	owned: u64
	for slot in ring.mutable.slots do if slot.owner == caller do owned += 1

	entryErr: shared.Error
	for i in 0 ..< n {
		if ring.mutable.inFlight == ring.sq.depth - 1 ||
		   ring.mutable.freeCount == 0 ||
		   owned >= cap {
			entryErr = .RingFull; break
		}
		slotBuf: [syscalls.CONTRACT_ACCESS_MAX]byte
		slot := slotBuf[:ring.sq.entrySize]
		if !user_copy_in_NO_LOCK(caller, slot, entriesPtr + i * ring.sq.entrySize) {
			entryErr = .InvalidAddress; break
		}
		if !contract_run_NO_LOCK(ring.rules, slot, 0, caller) {
			entryErr = .Denied; break
		}

		ring.mutable.freeCount -= 1
		token := ring.mutable.freeTokens[ring.mutable.freeCount]
		assert(ring.mutable.slots[token].state == .Free)
		assert(ring.mutable.slots[token].owner == nil)
		ok := endian.put_u16(slot[ring.sq.tokenOffset:], .Little, token)
		assert(ok)

		tail := ring.mutable.sqTail
		mem.copy(
			pmm.phys_to_ptr(ring.sq.phys + tail * ring.sq.entrySize),
			raw_data(slot),
			int(ring.sq.entrySize),
		)

		tokenOut := [1]u16{token}
		ok = user_copy_out_NO_LOCK(caller, tokensOutPtr + i * size_of(u16), tokenOut[:])
		assert(ok)

		ring.mutable.slots[token] = {
			owner = caller,
			state = .InFlight,
		}
		ring.mutable.inFlight += 1
		ring.mutable.sqTail = (tail + 1) % ring.sq.depth
		owned += 1
		accepted += 1
	}
	ring_assert_counters_NO_LOCK(ring)
	if accepted == 0 {
		assert(entryErr != .None)
		return 0, entryErr
	}
	intrinsics.atomic_thread_fence(.Release)
	intrinsics.volatile_store((^u32)(pmm.phys_to_ptr(ring.sq.doorbell)), u32(ring.mutable.sqTail))
	return accepted, .None
}

syscall_ring_reap :: proc(
	handle: int,
	tokensPtr, n, outPtr, waitPtr: u64,
) -> (
	finished: u64,
	err: shared.Error,
) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)

	if n == 0 do return 0, .InvalidSize

	ring_pool_read_lock()

	domain_read_lock(caller)

	ring, _ := ring_resolve_NO_LOCK(handle, caller) or_return
	if n > ring.sq.depth do return 0, .InvalidSize
	if !user_mapped_range_accessible_NO_LOCK(caller, tokensPtr, n * size_of(u16), false) do return 0, .InvalidAddress
	if !user_mapped_range_accessible_NO_LOCK(caller, outPtr, n * size_of(syscalls.RingReapEntry), true) do return 0, .InvalidAddress
	if !user_mapped_range_accessible_NO_LOCK(caller, waitPtr, size_of(syscalls.RingWait), true) do return 0, .InvalidAddress

	ring_lock(ring)

	wait := ring_cq_drain_NO_LOCK(ring)

	for i in 0 ..< n {
		token: [1]u16
		ok := user_copy_in_NO_LOCK(caller, token[:], tokensPtr + i * size_of(u16))
		assert(ok)

		entry: [1]syscalls.RingReapEntry
		if u64(token[0]) < ring.sq.depth {
			slot := ring.mutable.slots[token[0]]
			if slot.owner == caller && slot.state == .Done {
				entry[0] = {
					status = slot.status,
					done   = true,
				}
				ring_slot_free_NO_LOCK(ring, token[0])
				finished += 1
			}
		}
		ok = user_copy_out_NO_LOCK(caller, outPtr + i * size_of(syscalls.RingReapEntry), entry[:])
		assert(ok)
	}
	waitOut := [1]syscalls.RingWait{wait}
	ok := user_copy_out_NO_LOCK(caller, waitPtr, waitOut[:]); assert(ok)

	return finished, .None
}

ring_assert_counters_NO_LOCK :: proc(ring: ^Ring) {
	assert(ring.mutable.inFlight < ring.sq.depth)
	assert(ring.mutable.inFlight + ring.mutable.freeCount <= ring.sq.depth)
	assert(ring.mutable.sqTail < ring.sq.depth)
	assert(ring.mutable.cqHead < ring.cq.depth)
	assert(ring.mutable.cqPhase <= 1)
}

ring_slot_free_NO_LOCK :: proc(ring: ^Ring, token: u16) {
	assert(u64(token) < ring.sq.depth)
	assert(ring.mutable.slots[token].state != .Free)
	assert(ring.mutable.freeCount < ring.sq.depth)
	ring.mutable.slots[token] = {}
	ring.mutable.freeTokens[ring.mutable.freeCount] = token
	ring.mutable.freeCount += 1
}

ring_domain_orphan :: proc(pd: ^ProtectionDomain) {
	assert(pd != nil)
	ring_pool_read_lock()

	for ring in kernelState.ringPool.rings {
		if ring == nil do continue
		ring_lock(ring)

		for &slot, token in ring.mutable.slots {
			if slot.owner != pd do continue
			switch slot.state {
			case .Done:
				ring_slot_free_NO_LOCK(ring, u16(token))
			case .InFlight:
				slot.owner = nil
			case .Free:
				unreachable()
			}
		}
	}
}

syscall_ring_destroy :: proc(handle: int) -> (err: shared.Error) {
	caller := gs_read_cpustate().currentGrant.domain
	assert(caller != nil)

	ring_pool_write_lock()
	domain_read_lock(caller)

	ring, _ := ring_resolve_NO_LOCK(handle, caller) or_return
	ring_cq_drain_NO_LOCK(ring)

	if ring.mutable.inFlight > 0 do return .Busy
	if reserve(&kernelState.ringPool.freeSlots, len(kernelState.ringPool.freeSlots) + 1) != nil do return .OutOfMemory

	assert(kernelState.ringPool.rings[handle] == ring)
	kernelState.ringPool.rings[handle] = nil
	_, aErr := append(&kernelState.ringPool.freeSlots, handle)
	assert(aErr == .None)

	for u in ring.underlays do memory_underlay_release(u)
	delete(ring.rules)
	delete(ring.mutable.slots)
	delete(ring.mutable.freeTokens)
	free(ring)
	return .None

}
ring_resolve_NO_LOCK :: proc(
	handle: int,
	caller: ^ProtectionDomain,
) -> (
	ring: ^Ring,
	cap: u64,
	err: shared.Error,
) {
	assert(caller != nil)
	if handle < 0 || handle >= len(kernelState.ringPool.rings) do return nil, 0, .InvalidHandle
	if kernelState.ringPool.rings[handle] == nil do return nil, 0, .InvalidHandle
	ring = kernelState.ringPool.rings[handle]
	assert(ring.authorityPtr != nil)
	cap = user_range_covered_NO_LOCK(
		caller,
		u64(uintptr(ring.authorityPtr)),
		ring.authoritySize,
		true,
	)
	if cap == 0 do return nil, 0, .NoPermission
	return ring, cap, .None
}
ring_cq_drain_NO_LOCK :: proc(ring: ^Ring) -> (wait: syscalls.RingWait) {
	consumed: u64

	for consumed < ring.cq.depth {
		wordAddr :=
			ring.cq.phys + ring.mutable.cqHead * ring.cq.entrySize + (ring.cq.phaseOffset &~ 7)
		word := intrinsics.volatile_load((^u64)(pmm.phys_to_ptr(wordAddr)))
		phase := u8(word >> ((ring.cq.phaseOffset & 7) * 8 + ring.cq.phaseBit)) & 1
		if phase != ring.mutable.cqPhase {
			wait = {wordAddr, word}; break
		}
		intrinsics.atomic_thread_fence(.Acquire)

		cqe := ([^]u8)(
			pmm.phys_to_ptr(ring.cq.phys + ring.mutable.cqHead * ring.cq.entrySize),
		)[:ring.cq.entrySize]

		token, ok := endian.get_u16(cqe[ring.cq.tokenOffset:], .Little); assert(ok)
		status: u16
		status, ok = endian.get_u16(cqe[ring.cq.statusOffset:], .Little); assert(ok)

		if u64(token) < ring.sq.depth && ring.mutable.slots[token].state == .InFlight {
			assert(ring.mutable.inFlight > 0)
			ring.mutable.inFlight -= 1
			if ring.mutable.slots[token].owner == nil {
				ring_slot_free_NO_LOCK(ring, token)
			} else {
				ring.mutable.slots[token].state = .Done
				ring.mutable.slots[token].status = status
			}
		}
		ring.mutable.cqHead += 1
		if ring.mutable.cqHead == ring.cq.depth {
			ring.mutable.cqHead = 0
			ring.mutable.cqPhase ~= 1
		}
		consumed += 1
	}
	if consumed > 0 {
		intrinsics.atomic_thread_fence(.Release)
		intrinsics.volatile_store(
			(^u32)(pmm.phys_to_ptr(ring.cq.doorbell)),
			u32(ring.mutable.cqHead),
		)
	}
	ring_assert_counters_NO_LOCK(ring)
	return wait
}
