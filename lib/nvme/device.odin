package nvme
import ah "../../asm_helpers"
import "../clock"
import "base:intrinsics"
Device :: struct {
	regs:        Controller,
	cap:         CAP,
	admin:       AdminQueue,
	nsid:        u32,
	lbaSize:     u32,
	queueDepth:  u32,
	queueCount:  u32,
	nextQid:     u32,
	maxTransfer: u64,
	serial:      [20]u8,
	model:       [40]u8,
}


ADMIN_COMMANDS :: enum u8 {
	DELETE_IO_SQ = 0x00,
	CREATE_IO_SQ = 0x01,
	DELETE_IO_CQ = 0x04,
	CREATE_IO_CQ = 0x05,
	IDENTIFY     = 0x06,
	SET_FEATURES = 0x09,
}


IDENTIFY_CNS :: enum u8 {
	NAMESPACE      = 0x00,
	CONTROLLER     = 0x01,
	ACTIVE_NS_LIST = 0x07,
}
SET_FEATURES_FID_NUM_QUEUES :: u8(0x07)
ADMIN_TIMEOUT_MS :: u64(1000)
NUM_QUEUES_REQUEST_MAX :: u32(0xFFFE)


LBAFormat :: bit_field u32 {
	ms:    u16 | 16,
	lbads: u8  | 8,
	rp:    u8  | 2,
	_:     u8  | 6,
}


IdentifyController :: struct #packed {
	vid:    u16,
	ssvid:  u16,
	sn:     [20]u8,
	mn:     [40]u8,
	_:      [13]u8,
	mdts:   u8,
	_:      [434]u8,
	sqes:   u8,
	cqes:   u8,
	maxcmd: u16,
	nn:     u32,
}
#assert(size_of(IdentifyController) == 520)
#assert(offset_of(IdentifyController, sn) == 4)
#assert(offset_of(IdentifyController, mn) == 24)
#assert(offset_of(IdentifyController, sqes) == 512)
#assert(offset_of(IdentifyController, nn) == 516)
#assert(offset_of(IdentifyController, mdts) == 77)

IdentifyNamespace :: struct #packed {
	nsze:   u64,
	ncap:   u64,
	nuse:   u64,
	nsfeat: u8,
	nlbaf:  u8,
	flbas:  u8,
	_:      [101]u8,
	lbaf:   [16]LBAFormat,
}
#assert(offset_of(IdentifyNamespace, nlbaf) == 25)
#assert(offset_of(IdentifyNamespace, flbas) == 26)
#assert(offset_of(IdentifyNamespace, lbaf) == 128)


ActiveNamespaceList :: struct #packed {
	nsid: [1024]u32,
}
#assert(size_of(ActiveNamespaceList) == 4096)


AdminQueue :: struct {
	sq:      [^]Command,
	cq:      [^]Completion,
	sqTail:  u32,
	cqHead:  u32,
	depth:   u32,
	phase:   u8,
	nextCid: u16,
}


admin_execute_command :: proc(n: ^Device, cmd: Command) -> (result: u32, err: Error) {
	q := &n.admin
	assert(q.depth >= 2)
	assert(q.sqTail < q.depth && q.cqHead < q.depth)
	assert(q.phase <= 1)

	entry := cmd
	entry.header.commandId = q.nextCid
	q.nextCid += 1
	q.sq[q.sqTail] = entry
	q.sqTail = (q.sqTail + 1) % q.depth
	ah.mmio_write_u32(doorbell(n.regs, n.cap, 0, false), q.sqTail)

	deadline := clock.deadline_after_ms(ADMIN_TIMEOUT_MS)
	for intrinsics.volatile_load(&q.cq[q.cqHead].status).phase != q.phase {
		if clock.expired(deadline) do return 0, .Timeout
		intrinsics.cpu_relax()
	}
	done := q.cq[q.cqHead]
	assert(done.status.commandId == entry.header.commandId)

	q.cqHead += 1
	if q.cqHead == q.depth {
		q.cqHead = 0
		q.phase ~= 1
	}
	ah.mmio_write_u32(doorbell(n.regs, n.cap, 0, true), q.cqHead)
	return done.result, .None if completion_ok(done) else .Failed
}
