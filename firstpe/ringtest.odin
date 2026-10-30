// THROWAWAY: ring test, kept for reference until the user decides.
package firstpe
import "../lib/nvme"
import "../lib/shared"
import "../lib/syscalls"
import "base:intrinsics"

RING_TEST_WAIT_CYCLES :: u64(20_000_000_000)

RingTestParams :: struct {
	ready, done:                                       u64,
	handle:                                            int,
	nsid, lbaSize:                                     u32,
	allowedLba, deniedLba:                             u64,
	ownBuf, foreignBuf:                                u64,
	authority:                                         u64,
	writeErr, readErr, deniedReadErr, deniedWriteErr: shared.Error,
	foreignErr:                                        shared.Error,
	writeStatus, readStatus:                           u16,
	readMatch:                                         bool,
}
#assert(size_of(RingTestParams) == 120)

@(export)
ringTestParams: RingTestParams

ring_test_io :: proc "contextless" (
	p: ^RingTestParams,
	opcode: nvme.IoOpcode,
	lba, buf: u64,
) -> (
	status: u16,
	err: shared.Error,
) {
	cmds := [1]nvme.Command {
		{
			header = {opcode = u8(opcode)},
			namespaceId = p.nsid,
			dataAddr = buf,
			args = {io = {startBlock = lba}},
		},
	}
	tokens: [1]u16
	syscalls.syscall_debug_print_userspace("fpe: io opcode", u64(opcode))
	syscalls.syscall_debug_print_userspace("fpe: io lba", lba)
	_, submitErr := syscalls.syscall_ring_submit_userspace(p.handle, cmds[:], tokens[:])
	syscalls.syscall_debug_print_userspace("fpe: submit err", u64(submitErr))
	if submitErr != .None do return 0, submitErr
	syscalls.syscall_debug_print_userspace("fpe: token", u64(tokens[0]))

	out: [1]syscalls.RingReapEntry
	wait: syscalls.RingWait
	deadline := u64(intrinsics.read_cycle_counter()) + RING_TEST_WAIT_CYCLES
	for {
		_, reapErr := syscalls.syscall_ring_reap_userspace(p.handle, tokens[:], out[:], &wait)
		syscalls.syscall_debug_print_userspace("fpe: reap err", u64(reapErr))
		if reapErr != .None do return 0, reapErr
		syscalls.syscall_debug_print_userspace("fpe: reap done", u64(out[0].done))
		syscalls.syscall_debug_print_userspace("fpe: reap status", u64(out[0].status))
		syscalls.syscall_debug_print_userspace("fpe: wait addr", wait.addr)
		syscalls.syscall_debug_print_userspace("fpe: wait old", wait.old)
		if out[0].done do return out[0].status, .None
		if wait.addr == 0 do continue
		waitErr := syscalls.syscall_wait_on_userspace((^u64)(uintptr(wait.addr)), wait.old, deadline)
		syscalls.syscall_debug_print_userspace("fpe: wait_on err", u64(waitErr))
		if waitErr != .None do return 0, waitErr
	}
}

ring_test_client :: proc "contextless" (p: ^RingTestParams) {
	syscalls.syscall_debug_print_userspace("fpe: client start, params", u64(uintptr(p)))
	syscalls.syscall_debug_print_userspace("fpe: ready", p.ready)
	deadline := u64(intrinsics.read_cycle_counter()) + RING_TEST_WAIT_CYCLES
	for intrinsics.atomic_load(&p.ready) == 0 {
		readyErr := syscalls.syscall_wait_on_userspace(&p.ready, 0, deadline)
		syscalls.syscall_debug_print_userspace("fpe: ready wait_on err", u64(readyErr))
		if readyErr == .Timeout do return
	}
	syscalls.syscall_debug_print_userspace("fpe: handle", u64(p.handle))
	syscalls.syscall_debug_print_userspace("fpe: ownBuf", p.ownBuf)

	buf := ([^]byte)(uintptr(p.ownBuf))[:p.lbaSize]
	for &b, i in buf do b = byte(i * 7)
	p.writeStatus, p.writeErr = ring_test_io(p, .Write, p.allowedLba, p.ownBuf)

	for &b in buf do b = 0
	p.readStatus, p.readErr = ring_test_io(p, .Read, p.allowedLba, p.ownBuf)
	p.readMatch = true
	for b, i in buf do if b != byte(i * 7) do p.readMatch = false
	syscalls.syscall_debug_print_userspace("fpe: readMatch", u64(p.readMatch))

	_, p.deniedReadErr = ring_test_io(p, .Read, p.deniedLba, p.ownBuf)
	_, p.deniedWriteErr = ring_test_io(p, .Write, p.deniedLba, p.ownBuf)
	_, p.foreignErr = ring_test_io(p, .Read, p.allowedLba, p.foreignBuf)
	intrinsics.atomic_store(&p.done, 1)
	syscalls.syscall_debug_print_userspace("fpe: client done", 0)
}
