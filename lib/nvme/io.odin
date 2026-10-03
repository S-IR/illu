package nvme

import "../clock"
import "../syscalls"
import "../userschedule"
import "base:intrinsics"

QUEUE_DEPTH_MAX :: u32(64)
IO_DEFAULT_TIMEOUT_MS :: u64(1000)
CommandState :: enum u8 {
	Free,
	InFlight,
	Done,
	Failed,
}
Queue :: struct {
	using info:               QueueInfo,
	sqTail, cqHead, inFlight: u32,
	phase:                    u8,
	nextCid:                  u16,
	states:                   [QUEUE_DEPTH_MAX]CommandState,
}
Pending :: struct {
	queue: ^Queue,
	cid:   u16,
}
IoError :: enum {
	None,
	QueueFull,
	Timeout,
	DeviceFailed,
}

IoOpcode :: enum u8 {
	Flush = 0x00,
	Write = 0x01,
	Read  = 0x02,
}

queue_init :: proc(info: QueueInfo) -> Queue {
	assert(info.sq != nil && info.cq != nil)
	assert(info.sqDoorbell != nil && info.cqDoorbell != nil)
	assert(info.depth >= 2 && info.depth <= QUEUE_DEPTH_MAX)
	assert(info.qid != 0)
	assert(info.nsid != 0)
	assert(info.lbaSize >= 512 && info.lbaSize <= 4096)
	assert(info.lbaSize & (info.lbaSize - 1) == 0)
	return Queue{info = info, phase = 1}
}
@(private)
free_cid :: proc(q: ^Queue) -> (cid: u16, found: bool) {
	for i in 0 ..< q.depth {
		cid = u16((u32(q.nextCid) + i) % q.depth)
		if q.states[cid] == .Free do return cid, true
	}
	return 0, false
}
queue_submit :: proc(q: ^Queue, cmd: Command) -> (pending: Pending, err: IoError) {
	assert(q.sqTail < q.depth)
	assert(q.inFlight < q.depth)
	if q.inFlight == q.depth - 1 do return {}, .QueueFull
	cid, found := free_cid(q)
	if !found do return {}, .QueueFull

	entry := cmd
	entry.header.commandId = cid
	q.states[cid] = .InFlight
	q.nextCid = u16((u32(cid) + 1) % q.depth)

	q.sq[q.sqTail] = entry
	q.sqTail = (q.sqTail + 1) % q.depth
	q.inFlight += 1

	intrinsics.atomic_thread_fence(.Release)
	intrinsics.volatile_store(q.sqDoorbell, q.sqTail)
	return {queue = q, cid = cid}, .None
}
queue_poll :: proc(q: ^Queue) -> (ok: bool) {
	assert(q.cqHead < q.depth)
	assert(q.phase <= 1)
	if intrinsics.volatile_load(&q.cq[q.cqHead].status).phase != q.phase do return false
	assert(q.inFlight > 0)

	intrinsics.atomic_thread_fence(.Acquire)
	done := q.cq[q.cqHead]
	assert(done.sqId == q.qid)
	cid := done.status.commandId
	assert(u32(cid) < q.depth)
	assert(q.states[cid] == .InFlight)
	q.states[cid] = .Done if completion_ok(done) else .Failed

	q.cqHead += 1
	if q.cqHead == q.depth {
		q.cqHead = 0
		q.phase ~= 1
	}
	q.inFlight -= 1
	intrinsics.volatile_store(q.cqDoorbell, q.cqHead)
	return true

}
wait :: proc(p: Pending, timeout := IO_DEFAULT_TIMEOUT_MS) -> IoError {
	q := p.queue
	assert(q != nil)
	assert(u32(p.cid) < q.depth)
	assert(q.states[p.cid] != .Free)
	deadline := clock.deadline_after_ms(timeout)
	for q.states[p.cid] == .InFlight {
		if queue_poll(q) do continue
		word := completion_word(q)
		old := intrinsics.volatile_load(word)
		if (transmute(CompletionStatus)u32(old >> 32)).phase == q.phase do continue

		switch syscalls.syscall_wait_on_userspace(word, old, deadline) {
		case .None:
		case .TimedOut:
			return .Timeout
		case .InvalidAddress, .InvalidSaveArea:
			panic("nvme wait: wait_on rejected")
		}
	}
	state := q.states[p.cid]
	q.states[p.cid] = .Free
	return .None if state == .Done else .DeviceFailed

}

queue_io :: proc(q: ^Queue, opcode: IoOpcode, startBlock: u64, block: []u8) -> (Pending, IoError) {
	assert(opcode == .Read || opcode == .Write)
	assert(len(block) == int(q.lbaSize))
	assert(uintptr(raw_data(block)) % uintptr(q.lbaSize) == 0)
	return queue_submit(
		q,
		{
			header = {opcode = u8(opcode)},
			namespaceId = q.nsid,
			dataAddr = u64(uintptr(raw_data(block))),
			args = {io = {startBlock = startBlock}},
		},
	)
}
queue_io_sync :: proc(q: ^Queue, opcode: IoOpcode, startBlock: u64, block: []u8) -> IoError {
	pending := queue_io(q, opcode, startBlock, block) or_return
	return wait(pending)

}
@(private)
completion_word :: proc(q: ^Queue) -> ^u64 {
	#assert(offset_of(Completion, sqHead) == 8)
	return (^u64)(uintptr(&q.cq[q.cqHead]) + offset_of(Completion, sqHead))
}
