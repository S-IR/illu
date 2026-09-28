package nvme

import "../clock"
import "base:intrinsics"
Queue :: struct {
	using info:               QueueInfo,
	sqTail, cqHead, inFlight: u32,
	phase:                    u8,
	nextCid:                  u16,
}
IoError :: enum u8 {
	None,
	QueueFull,
	Timeout,
	DeviceFailed,
}

queue_submit :: proc(q: ^Queue, cmd: Command) -> (commandId: u16, err: IoError) {
	assert(q.sqTail < q.depth)
	assert(q.inFlight < q.depth)
	if q.inFlight == q.depth - 1 do return 0, .QueueFull

	entry := cmd
	entry.header.commandId = q.nextCid

	q.sq[q.sqTail] = entry
	q.sqTail = (q.sqTail + 1) % q.depth
	q.inFlight += 1
	q.nextCid += 1

	intrinsics.atomic_thread_fence(.Release)
	intrinsics.volatile_store(q.sqDoorbell, q.sqTail)
	return entry.header.commandId, .None
}
queue_poll :: proc(q: ^Queue) -> (done: Completion, ok: bool) {
	assert(q.cqHead < q.depth)
	assert(q.phase <= 1)
	if intrinsics.volatile_load(&q.cq[q.cqHead].status).phase != q.phase do return {}, false
	assert(q.inFlight > 0)

	intrinsics.atomic_thread_fence(.Acquire)
	done = q.cq[q.cqHead]
	assert(done.sqId == q.qid)

	q.cqHead += 1
	if q.cqHead == q.depth {
		q.cqHead = 0
		q.phase ~= 1
	}
	q.inFlight -= 1
	intrinsics.volatile_store(q.cqDoorbell, q.cqHead)
	return done, true
}
queue_init :: proc(info: QueueInfo) -> Queue {
	assert(info.sq != nil && info.cq != nil)
	assert(info.sqDoorbell != nil && info.cqDoorbell != nil)
	assert(info.depth >= 2 && info.depth <= u32(max(u16)) + 1)
	assert(info.qid != 0)
	assert(info.nsid != 0)
	assert(info.lbaSize >= 512 && info.lbaSize <= 4096)
	assert(info.lbaSize & (info.lbaSize - 1) == 0)
	return Queue{info = info, phase = 1}
}
IO_TIMEOUT_MS :: u64(1000)

IoOpcode :: enum u8 {
	Flush = 0x00,
	Write = 0x01,
	Read  = 0x02,
}
queue_io_sync :: proc(q: ^Queue, opcode: IoOpcode, startBlock: u64, block: []u8) -> IoError {
	assert(opcode == .Read || opcode == .Write)
	assert(q.inFlight == 0)
	assert(len(block) == int(q.lbaSize))
	assert(uintptr(raw_data(block)) % uintptr(q.lbaSize) == 0)

	commandId := queue_submit(
		q,
		{
			header = {opcode = u8(opcode)},
			namespaceId = q.nsid,
			dataAddr = u64(uintptr(raw_data(block))),
			args = {io = {startBlock = startBlock}},
		},
	) or_return

	deadline := clock.deadline_after_ms(IO_TIMEOUT_MS)

	for {
		done, polled := queue_poll(q)
		if polled {
			assert(done.status.commandId == commandId)
			return .None if completion_ok(done) else .DeviceFailed
		}
		if clock.expired(deadline) do return .Timeout
		intrinsics.cpu_relax()
	}
}
