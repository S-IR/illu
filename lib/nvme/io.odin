package nvme
import "../shared"
import "../syscalls"
import "base:intrinsics"

QUEUE_DEPTH_SPEC_MAX :: u32(max(u16)) + 1
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
	states:                   []CommandState,
}
Pending :: struct {
	queue: ^Queue,
	cid:   u16,
}
IoOpcode :: enum u8 {
	Flush = 0x00,
	Write = 0x01,
	Read  = 0x02,
}

queue_init :: proc(info: QueueInfo) -> (q: Queue, err: shared.Error) {
	assert(info.sq != nil && info.cq != nil)
	assert(info.sqDoorbell != nil && info.cqDoorbell != nil)
	assert(info.depth >= 2 && info.depth <= QUEUE_DEPTH_SPEC_MAX)
	assert(info.qid != 0)
	assert(info.nsid != 0)
	assert(info.lbaSize >= 512 && info.lbaSize <= 4096)
	assert(info.lbaSize & (info.lbaSize - 1) == 0)

	assert(info.maxTransfer >= u64(info.lbaSize))
	assert(info.maxTransfer % shared.PAGE_SIZE == 0)

	states, allocErr := make([]CommandState, int(info.depth))
	if allocErr != .None do return {}, .OutOfMemory
	return Queue{info = info, phase = 1, states = states}, .None
}
@(private)
free_cid :: proc(q: ^Queue) -> (cid: u16, found: bool) {
	for i in 0 ..< q.depth {
		cid = u16((u32(q.nextCid) + i) % q.depth)
		if q.states[cid] == .Free do return cid, true
	}
	return 0, false
}
queue_submit :: proc(q: ^Queue, cmd: Command) -> (pending: Pending, err: shared.Error) {
	assert(q.sqTail < q.depth)
	assert(q.inFlight < q.depth)
	if q.inFlight == q.depth - 1 do return {}, .NvmeQueueFull
	cid, found := free_cid(q)
	if !found do return {}, .NvmeQueueFull

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
wait :: proc(p: Pending, deadline: u64) -> shared.Error {
	q := p.queue
	assert(q != nil)
	assert(u32(p.cid) < q.depth)
	assert(q.states[p.cid] != .Free)
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
	return .None if state == .Done else .NvmeFailed

}

queue_io :: proc(
	q: ^Queue,
	opcode: IoOpcode,
	startBlock: u64,
	bufs: [][]u8,
	prpList: []u64,
	fua: bool,
) -> (
	Pending,
	shared.Error,
) {
	opOk := opcode == .Read || opcode == .Write
	if !shared.assert(opOk) do return {}, .InvalidAPICall

	if !shared.assert(len(bufs) > 0) do return {}, .InvalidAPICall
	total: u64
	for buf, i in bufs {
		start := uintptr(raw_data(buf))
		end := start + uintptr(len(buf))
		align := uintptr(4 if i == 0 else shared.PAGE_SIZE)
		endOk := i == len(bufs) - 1 || end % shared.PAGE_SIZE == 0
		if !shared.assert(len(buf) > 0) do return {}, .InvalidAPICall
		if !shared.assert(start % align == 0) do return {}, .InvalidAPICall
		if !shared.assert(endOk) do return {}, .InvalidAPICall
		total += u64(len(buf))
	}
	blocksOk := total % u64(q.lbaSize) == 0
	listOk := len(prpList) == prp_list_len(bufs)
	listAddr := uintptr(raw_data(prpList))
	if !shared.assert(blocksOk) do return {}, .InvalidAPICall
	if !shared.assert(total <= q.maxTransfer) do return {}, .InvalidAPICall
	if !shared.assert(listOk) do return {}, .InvalidAPICall
	if !shared.assert(listAddr % shared.PAGE_SIZE == 0) do return {}, .InvalidAPICall

	cmd := Command {
		header = {opcode = u8(opcode)},
		namespaceId = q.nsid,
		args = {
			io = {
				control = {forceUnitAccess = fua},
				startBlock = startBlock,
				blockCountMinus1 = u16(total / u64(q.lbaSize) - 1),
			},
		},
	}
	prp_fill(&cmd, bufs, prpList)
	return queue_submit(q, cmd)

}
queue_flush :: proc(q: ^Queue) -> (Pending, shared.Error) {
	cmd := Command {
		header = {opcode = u8(IoOpcode.Flush)},
		namespaceId = q.nsid,
	}
	return queue_submit(q, cmd)
}


@(private)
completion_word :: proc(q: ^Queue) -> ^u64 {
	#assert(offset_of(Completion, sqHead) == 8)
	return (^u64)(uintptr(&q.cq[q.cqHead]) + offset_of(Completion, sqHead))
}

PRP_ENTRIES_PER_PAGE :: shared.PAGE_SIZE / size_of(u64)

@(private)
prp_page_count :: proc(bufs: [][]u8) -> (pages: int) {
	for buf in bufs {
		start := uintptr(raw_data(buf))
		end := start + uintptr(len(buf))
		firstPage := start &~ (shared.PAGE_SIZE - 1)
		endPage := (end + shared.PAGE_SIZE - 1) &~ (shared.PAGE_SIZE - 1)
		pages += int((endPage - firstPage) / shared.PAGE_SIZE)
	}
	return pages
}

prp_list_len :: proc(bufs: [][]byte) -> int {
	pages := prp_page_count(bufs)
	if pages <= 2 do return 0
	entries := pages - 1
	chains := (entries - 2) / (PRP_ENTRIES_PER_PAGE - 1)
	return entries + chains
}

@(private)
prp_fill :: proc(cmd: ^Command, bufs: [][]byte, prpList: []u64) {
	assert(len(bufs) > 0)
	assert(uintptr(raw_data(prpList)) % shared.PAGE_SIZE == 0)
	assert(len(prpList) == prp_list_len(bufs))
	cmd.dataAddr = u64(uintptr(raw_data(bufs[0])))
	pageIdx, listIdx := 0, 0
	for buf, i in bufs {
		start := uintptr(raw_data(buf))
		end := start + uintptr(len(buf))
		assert(len(buf) > 0)
		assert(start % 4 == 0 if i == 0 else start % shared.PAGE_SIZE == 0)
		if i < len(bufs) - 1 do assert(end % shared.PAGE_SIZE == 0)

		for page := start &~ (shared.PAGE_SIZE - 1); page < end; page += shared.PAGE_SIZE {
			switch {
			case pageIdx == 0:
			case len(prpList) == 0:
				cmd.dataAddr2 = u64(page)
			case:
				lastSlot := PRP_ENTRIES_PER_PAGE - 1
				isLastSlotOfPage := listIdx % PRP_ENTRIES_PER_PAGE == lastSlot
				if isLastSlotOfPage && listIdx < len(prpList) - 1 {
					prpList[listIdx] = u64(uintptr(&prpList[listIdx + 1]))
					listIdx += 1
				}
				prpList[listIdx] = u64(page)
				listIdx += 1

			}
			pageIdx += 1

		}
	}
	if len(prpList) > 0 do cmd.dataAddr2 = u64(uintptr(raw_data(prpList)))
	assert(listIdx == len(prpList))
}
