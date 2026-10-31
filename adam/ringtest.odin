// THROWAWAY: ring test, kept for reference until the user decides.
package adam
import "../lib/shared"
import "../lib/syscalls"
import "base:intrinsics"

RingTestEntry :: struct {
	token: u16,
	pad:   [6]byte,
	value: u64,
}
#assert(size_of(RingTestEntry) == 16)

RingTestCqe :: struct {
	pad:    [12]byte,
	token:  u16,
	status: u16,
}
#assert(size_of(RingTestCqe) == 16)

RingTestPage :: struct {
	sq:         [4]RingTestEntry,
	cq:         [4]RingTestCqe,
	sqDoorbell: u32,
	cqDoorbell: u32,
	authority:  [3]byte,
}
#assert(offset_of(RingTestPage, cq) % 8 == 0)

ring_test_complete :: proc(cqe: ^RingTestCqe, token, status, phase: u16) {
	cqe.token = token
	intrinsics.atomic_store_explicit(&cqe.status, status << 1 | phase, .Release)
}

ring_test :: proc() {
	regions := [1]syscalls.MMapRegion{{pageSize = ._4KB, count = 1, flags = {.Present, .Write}}}
	addr, mmapErr := syscalls.syscall_mmap_userspace(regions[:])
	assert(mmapErr == .None)
	page := (^RingTestPage)(addr)

	rules := [?]syscalls.ContractRule {
		{op = .Load64, a = 2, imm = 8},
		{op = .Imm, a = 3, imm = 42},
		{op = .Jne, a = 2, b = 3, imm = 4},
		{op = .Accept},
	}
	desc := syscalls.RingDesc {
		authorityPtr = u64(uintptr(&page.authority)),
		sq = {
			phys = u64(uintptr(&page.sq)),
			entrySize = size_of(RingTestEntry),
			depth = len(page.sq),
			doorbell = u64(uintptr(&page.sqDoorbell)),
			tokenOffset = u64(offset_of(RingTestEntry, token)),
		},
		cq = {
			phys = u64(uintptr(&page.cq)),
			entrySize = size_of(RingTestCqe),
			depth = len(page.cq),
			doorbell = u64(uintptr(&page.cqDoorbell)),
			tokenOffset = u64(offset_of(RingTestCqe, token)),
			phaseOffset = u64(offset_of(RingTestCqe, status)),
			phaseBit = 0,
			statusOffset = u64(offset_of(RingTestCqe, status)),
		},
		authoritySize = len(page.authority),
		rulesPtr = u64(uintptr(&rules)),
		rulesCount = len(rules),
	}

	overlapping := desc
	overlapping.cq.phys = overlapping.sq.phys
	handle, err := syscalls.syscall_ring_create_userspace(&overlapping)
	assert(err == .InvalidRing)

	handle, err = syscalls.syscall_ring_create_userspace(&desc)
	assert(err == .None)

	good := [4]RingTestEntry{{value = 42}, {value = 42}, {value = 42}, {value = 42}}
	evil := [1]RingTestEntry{{value = 7}}
	tokens: [4]u16
	out: [4]syscalls.RingReapEntry
	wait: syscalls.RingWait
	accepted, finished: u64

	accepted, err = syscalls.syscall_ring_submit_userspace(handle, evil[:], tokens[:])
	assert(err == .Denied && accepted == 0)

	accepted, err = syscalls.syscall_ring_submit_userspace(handle, good[:1], tokens[:])
	assert(err == .None && accepted == 1)
	assert(page.sq[0].token == tokens[0] && page.sq[0].value == 42 && page.sqDoorbell == 1)

	finished, err = syscalls.syscall_ring_reap_userspace(handle, tokens[:1], out[:], &wait)
	assert(err == .None && finished == 0 && !out[0].done)
	assert(wait.addr == u64(uintptr(&page.cq[0])) + 8)
	assert(syscalls.syscall_ring_destroy_userspace(handle) == .Busy)

	ring_test_complete(&page.cq[0], tokens[0], 5, 1)
	finished, err = syscalls.syscall_ring_reap_userspace(handle, tokens[:1], out[:], &wait)
	assert(err == .None && finished == 1 && out[0].done && out[0].status == 5 << 1 | 1)
	assert(page.cqDoorbell == 1)

	accepted, err = syscalls.syscall_ring_submit_userspace(handle, good[:], tokens[:])
	assert(err == .None && accepted == 3)
	accepted, err = syscalls.syscall_ring_submit_userspace(handle, good[:1], tokens[3:])
	assert(err == .RingFull && accepted == 0)

	for i in 0 ..< 3 do ring_test_complete(&page.cq[i + 1], tokens[i], 0, 1)
	finished, err = syscalls.syscall_ring_reap_userspace(handle, tokens[:3], out[:], &wait)
	assert(err == .None && finished == 3)
	assert(page.cqDoorbell == 0 && wait.addr == u64(uintptr(&page.cq[0])) + 8)

	finished, err = syscalls.syscall_ring_reap_userspace(handle, tokens[:3], out[:], &wait)
	assert(err == .None && finished == 0)

	assert(syscalls.syscall_ring_destroy_userspace(handle) == .None)
	assert(syscalls.syscall_ring_destroy_userspace(handle) == .InvalidHandle)
	finished, err = syscalls.syscall_ring_reap_userspace(handle, tokens[:1], out[:], &wait)
	assert(err == .InvalidHandle)

	assert(syscalls.mem_free_userspace(u64(uintptr(addr))) == .None)
	syscalls.syscall_debug_print_userspace("ring test ok")
}

memory_access_test :: proc() {
	regions := [1]syscalls.MMapRegion{{pageSize = ._4KB, count = 1, flags = {.Present, .Write}}}
	addr, mmapErr := syscalls.syscall_mmap_userspace(regions[:])
	assert(mmapErr == .None)
	page := u64(uintptr(addr))

	written := [8]byte{1, 2, 3, 4, 5, 6, 7, 8}
	assert(syscalls.syscall_contract_memory_access_userspace(page, written[:], .Write) == .None)
	got: [8]byte
	assert(syscalls.syscall_contract_memory_access_userspace(page, got[:], .Read) == .None)
	assert(got == written)

	pastEnd: [16]byte
	pastEndErr := syscalls.syscall_contract_memory_access_userspace(
		page + shared.PAGE_SIZE - 8,
		pastEnd[:],
		.Read,
	)
	assert(pastEndErr == .OutOfBounds)
	notOwnedErr := syscalls.syscall_contract_memory_access_userspace(
		~u64(shared.PAGE_SIZE - 1),
		got[:],
		.Read,
	)
	assert(notOwnedErr == .NotOwned)

	assert(syscalls.mem_free_userspace(page) == .None)
	syscalls.syscall_debug_print_userspace("memory access test ok")
}
