package nvme
import "../shared"
import "../syscalls"
import "core:math"
NVME_PHASE_OFFSET :: offset_of(Completion, status) + 2

FLAGS_OFFSET :: 1
CID_OFFSET :: 2
MPTR_OFFSET :: 16

CONTRACT_READ_PATH :: 30
CONTRACT_WRITE_PATH :: 32
CONTRACT_FLUSH_PATH :: 34
CONTRACT_DENY :: 36

contract_rules :: proc(
	nsid, lbaSize: u32,
	lo, hi: u64,
) -> (
	rules: [CONTRACT_DENY]syscalls.ContractRule,
) {
	assert(nsid != 0)
	assert(math.is_power_of_two(int(lbaSize)))
	assert(lbaSize >= 512 && lbaSize <= 4096)
	assert(lo < hi)


	rules = [CONTRACT_DENY]syscalls.ContractRule {
		{op = .Imm, a = 7, imm = 0},
		{op = .Load8, a = 2, imm = FLAGS_OFFSET},
		{op = .Jne, a = 2, b = 7, imm = CONTRACT_DENY},
		{op = .Load32, a = 2, imm = u64(offset_of(Command, namespaceId))},
		{op = .Imm, a = 3, imm = u64(nsid)},
		{op = .Jne, a = 2, b = 3, imm = CONTRACT_DENY},
		{op = .Load64, a = 2, imm = MPTR_OFFSET},
		{op = .Jne, a = 2, b = 7, imm = CONTRACT_DENY},
		{op = .Load64, a = 2, imm = u64(offset_of(Command, dataAddr2))},
		{op = .Jne, a = 2, b = 7, imm = CONTRACT_DENY},
		{op = .Load64, a = 4, imm = u64(offset_of(Command, dataAddr))},
		{op = .Load8, a = 6, imm = 0},
		{op = .Imm, a = 3, imm = u64(IoOpcode.Flush)},
		{op = .Jeq, a = 6, b = 3, imm = CONTRACT_FLUSH_PATH},
		{
			op = .Load16,
			a = 2,
			imm = u64(offset_of(Command, args) + offset_of(IoArgs, blockCountMinus1)),
		},
		{op = .Jne, a = 2, b = 7, imm = CONTRACT_DENY},
		{op = .Load64, a = 2, imm = u64(offset_of(Command, args) + offset_of(IoArgs, startBlock))},
		{op = .Imm, a = 3, imm = lo},
		{op = .Jlt, a = 2, b = 3, imm = CONTRACT_DENY},
		{op = .Imm, a = 3, imm = hi},
		{op = .Jge, a = 2, b = 3, imm = CONTRACT_DENY},
		{op = .Imm, a = 3, imm = shared.PAGE_SIZE - 1},
		{op = .And, a = 3, b = 4},
		{op = .Jne, a = 3, b = 7, imm = CONTRACT_DENY},
		{op = .Imm, a = 5, imm = u64(lbaSize)},
		{op = .Imm, a = 3, imm = u64(IoOpcode.Read)},
		{op = .Jeq, a = 6, b = 3, imm = CONTRACT_READ_PATH},
		{op = .Imm, a = 3, imm = u64(IoOpcode.Write)},
		{op = .Jeq, a = 6, b = 3, imm = CONTRACT_WRITE_PATH},
		{op = .Jeq, a = 7, b = 7, imm = CONTRACT_DENY},
		{op = .HasPermW, a = 4, b = 5},
		{op = .Accept},
		{op = .HasPermR, a = 4, b = 5},
		{op = .Accept},
		{op = .Jne, a = 4, b = 7, imm = CONTRACT_DENY},
		{op = .Accept},
	}
	assert(
		rules[CONTRACT_READ_PATH].op == .HasPermW &&
		rules[CONTRACT_WRITE_PATH].op == .HasPermR &&
		rules[CONTRACT_FLUSH_PATH].op == .Jne,
	)

	return rules

}
ring_desc :: proc(
	info: QueueInfo,
	authorityPtr: u64,
	authoritySize: u64,
	rules: []syscalls.ContractRule,
) -> syscalls.RingDesc {
	assert(authorityPtr != 0)
	assert(authoritySize >= 1 && authoritySize < u64(info.depth))
	assert(len(rules) > 0)
	cq := u64(uintptr(info.cq))

	return {
		authorityPtr = authorityPtr,
		sq = {
			phys = u64(uintptr(info.sq)),
			entrySize = size_of(Command),
			depth = u64(info.depth),
			doorbell = u64(uintptr(info.sqDoorbell)),
			tokenOffset = CID_OFFSET,
		},
		cq = {
			phys = cq,
			entrySize = size_of(Completion),
			depth = u64(info.depth),
			doorbell = u64(uintptr(info.cqDoorbell)),
			tokenOffset = u64(offset_of(Completion, status)),
			phaseOffset = u64(NVME_PHASE_OFFSET),
			phaseBit = 0,
			statusOffset = u64(NVME_PHASE_OFFSET),
		},
		authoritySize = authoritySize,
		rulesPtr = u64(uintptr(raw_data(rules))),
		rulesCount = u64(len(rules)),
	}
}
