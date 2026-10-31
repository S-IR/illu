package syscalls
import "../shared"

RingSq :: struct {
	phys, entrySize, depth, doorbell, tokenOffset: u64,
}

RingCq :: struct {
	phys, entrySize, depth, doorbell, tokenOffset: u64,
	phaseOffset, phaseBit, statusOffset:           u64,
}

RingDesc :: struct {
	authorityPtr:  u64,
	sq:            RingSq,
	cq:            RingCq,
	authoritySize: u64,
	rulesPtr:      u64,
	rulesCount:    u64,
}

RingReapEntry :: struct {
	status: u16,
	done:   bool,
}
#assert(size_of(RingReapEntry) == 4)

RingWait :: struct {
	addr, old: u64,
}

when !ODIN_TEST && !KERNEL_BUILD {
	syscall_ring_create_userspace :: proc "contextless" (
		desc: ^RingDesc,
	) -> (
		handle: int,
		err: shared.Error,
	) {
		rawErr, rawHandle := syscall_ring_create(u64(uintptr(desc)))
		return rawHandle, shared.Error(rawErr)
	}

	syscall_ring_submit_userspace :: proc "contextless" (
		handle: int,
		entries: []$T,
		tokensOut: []u16,
	) -> (
		accepted: u64,
		err: shared.Error,
	) {
		assert_contextless(len(tokensOut) >= len(entries))
		rawErr, rawAccepted := syscall_ring_submit(
			handle,
			u64(uintptr(raw_data(entries))),
			u64(len(entries)),
			u64(uintptr(raw_data(tokensOut))),
		)
		return rawAccepted, shared.Error(rawErr)
	}

	syscall_ring_reap_userspace :: proc "contextless" (
		handle: int,
		tokens: []u16,
		out: []RingReapEntry,
		wait: ^RingWait,
	) -> (
		finished: u64,
		err: shared.Error,
	) {
		assert_contextless(len(out) >= len(tokens))
		rawErr, rawFinished := syscall_ring_reap(
			handle,
			u64(uintptr(raw_data(tokens))),
			u64(len(tokens)),
			u64(uintptr(raw_data(out))),
			u64(uintptr(wait)),
		)
		return rawFinished, shared.Error(rawErr)
	}

	syscall_ring_destroy_userspace :: proc "contextless" (handle: int) -> shared.Error {
		return shared.Error(syscall_ring_destroy(handle))
	}
}
