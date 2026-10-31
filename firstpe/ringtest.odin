// THROWAWAY: ring test, kept for reference until the user decides.
package firstpe
import "../lib/nvme"
import "../lib/shared"
import "../lib/syscalls"
import "base:intrinsics"

RING_TEST_WAIT_CYCLES :: u64(20_000_000_000)

RingTestParams :: struct {
	ready, done:                                      u64,
	handle, otherHandle:                              int,
	nsid, lbaSize:                                    u32,
	allowedLba, deniedLba:                            u64,
	ownBuf, foreignBuf:                               u64,
	authority, cq:                                    u64,
	capAccepted:                                      u64,
	writeErr, readErr, deniedReadErr, deniedWriteErr: shared.Error,
	foreignErr, capErr, capFullErr, otherErr:         shared.Error,
	authWriteErr, authReadErr, cqWriteErr, cqReadErr: shared.Error,
	writeStatus, readStatus:                          u16,
	readMatch, authMatch:                             bool,
}
#assert(size_of(RingTestParams) == 200)

@(export)
ringTestParams: RingTestParams

ring_test_cmd :: proc "contextless" (
	p: ^RingTestParams,
	opcode: nvme.IoOpcode,
	lba, buf: u64,
) -> nvme.Command {
	return {
		header = {opcode = u8(opcode)},
		namespaceId = p.nsid,
		dataAddr = buf,
		args = {io = {startBlock = lba}},
	}
}

ring_test_wait :: proc "contextless" (handle: int, token: u16) -> (status: u16, err: shared.Error) {
	tokens := [1]u16{token}
	out: [1]syscalls.RingReapEntry
	wait: syscalls.RingWait
	deadline := u64(intrinsics.read_cycle_counter()) + RING_TEST_WAIT_CYCLES
	for {
		_ = syscalls.syscall_ring_reap_userspace(handle, tokens[:], out[:], &wait) or_return
		if out[0].done do return out[0].status, .None
		if wait.addr == 0 do continue
		syscalls.syscall_wait_on_userspace((^u64)(uintptr(wait.addr)), wait.old, deadline) or_return
	}
}

ring_test_io :: proc "contextless" (
	p: ^RingTestParams,
	opcode: nvme.IoOpcode,
	lba, buf: u64,
) -> (
	status: u16,
	err: shared.Error,
) {
	cmds := [1]nvme.Command{ring_test_cmd(p, opcode, lba, buf)}
	tokens: [1]u16
	_ = syscalls.syscall_ring_submit_userspace(p.handle, cmds[:], tokens[:]) or_return
	return ring_test_wait(p.handle, tokens[0])
}

ring_test_client :: proc "contextless" (p: ^RingTestParams) {
	syscalls.syscall_debug_print_userspace("fpe: client start, params", u64(uintptr(p)))
	deadline := u64(intrinsics.read_cycle_counter()) + RING_TEST_WAIT_CYCLES
	for intrinsics.atomic_load(&p.ready) == 0 {
		readyErr := syscalls.syscall_wait_on_userspace(&p.ready, 0, deadline)
		if readyErr == .Timeout do return
	}

	buf := ([^]byte)(uintptr(p.ownBuf))[:p.lbaSize]
	for &b, i in buf do b = byte(i * 7)
	p.writeStatus, p.writeErr = ring_test_io(p, .Write, p.allowedLba, p.ownBuf)

	for &b in buf do b = 0
	p.readStatus, p.readErr = ring_test_io(p, .Read, p.allowedLba, p.ownBuf)
	p.readMatch = true
	for b, i in buf do if b != byte(i * 7) do p.readMatch = false

	_, p.deniedReadErr = ring_test_io(p, .Read, p.deniedLba, p.ownBuf)
	_, p.deniedWriteErr = ring_test_io(p, .Write, p.deniedLba, p.ownBuf)
	_, p.foreignErr = ring_test_io(p, .Read, p.allowedLba, p.foreignBuf)

	cmds := [2]nvme.Command {
		ring_test_cmd(p, .Read, p.allowedLba, p.ownBuf),
		ring_test_cmd(p, .Read, p.allowedLba, p.ownBuf),
	}
	tokens: [2]u16
	fullTokens: [1]u16
	p.capAccepted, p.capErr = syscalls.syscall_ring_submit_userspace(p.handle, cmds[:], tokens[:])
	fullAccepted: u64
	fullAccepted, p.capFullErr = syscalls.syscall_ring_submit_userspace(
		p.handle,
		cmds[:1],
		fullTokens[:],
	)
	for t in tokens[:min(p.capAccepted, len(tokens))] do ring_test_wait(p.handle, t)
	if fullAccepted > 0 do ring_test_wait(p.handle, fullTokens[0])

	otherTokens: [1]u16
	_, p.otherErr = syscalls.syscall_ring_submit_userspace(p.otherHandle, cmds[:1], otherTokens[:])

	authByte := [1]byte{0xA5}
	p.authWriteErr = syscalls.syscall_contract_memory_access_userspace(p.authority, authByte[:], .Write)
	authByte[0] = 0
	p.authReadErr = syscalls.syscall_contract_memory_access_userspace(p.authority, authByte[:], .Read)
	p.authMatch = authByte[0] == 0xA5

	cqWord: [8]byte
	p.cqReadErr = syscalls.syscall_contract_memory_access_userspace(p.cq, cqWord[:], .Read)
	p.cqWriteErr = syscalls.syscall_contract_memory_access_userspace(p.cq, cqWord[:], .Write)

	intrinsics.atomic_store(&p.done, 1)
	syscalls.syscall_debug_print_userspace("fpe: client done", 0)
}
