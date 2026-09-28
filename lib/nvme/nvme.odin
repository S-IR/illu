package nvme


CommandHeader :: bit_field u32 {
	opcode:    u8  | 8,
	_:         u8  | 8,
	commandId: u16 | 16,
}
Command :: struct #packed {
	header:      CommandHeader,
	namespaceId: u32,
	_:           [4]u32,
	dataAddr:    u64,
	dataAddr2:   u64,
	args:        CommandArgs,
}
#assert(size_of(Command) == 64)
#assert(offset_of(Command, dataAddr) == 24)
#assert(offset_of(Command, args) == 40)
CommandArgs :: struct #raw_union {
	io:          IoArgs,
	identify:    IdentifyArgs,
	createCq:    CreateCqArgs,
	createSq:    CreateSqArgs,
	deleteQueue: DeleteQueueArgs,
	setFeatures: SetFeaturesArgs,
}
#assert(size_of(CommandArgs) == 24)

IoArgs :: struct #packed {
	startBlock:       u64,
	blockCountMinus1: u16,
	_:                [14]u8,
}
IdentifyArgs :: struct #packed {
	what: u8,
	_:    [23]u8,
}
QueueFlag :: enum u16 {
	Contiguous,
	InterruptsEnable,
}
QueueFlags :: bit_set[QueueFlag;u16]
CreateCqArgs :: struct #packed {
	queueId:         u16,
	sizeMinus1:      u16,
	flags:           QueueFlags,
	interruptVector: u16,
	_:               [16]u8,
}
CreateSqArgs :: struct #packed {
	queueId:           u16,
	sizeMinus1:        u16,
	flags:             QueueFlags,
	completionQueueId: u16,
	_:                 [16]u8,
}
DeleteQueueArgs :: struct #packed {
	queueId: u16,
	_:       [22]u8,
}
SetFeaturesArgs :: struct #packed {
	feature: u8,
	_:       [3]u8,
	value:   u32,
	_:       [16]u8,
}
CompletionStatus :: bit_field u32 {
	commandId: u16 | 16,
	phase:     u8  | 1,
	code:      u8  | 8,
	codeType:  u8  | 3,
	_:         u8  | 4,
}
Completion :: struct #packed {
	result: u32,
	_:      u32,
	sqHead: u16,
	sqId:   u16,
	status: CompletionStatus,
}
#assert(size_of(Completion) == 16)
#assert(offset_of(Completion, status) == 12)
completion_ok :: proc(c: Completion) -> bool {
	return c.status.code == 0 && c.status.codeType == 0
}
QueueInfo :: struct {
	sq:         [^]Command,
	cq:         [^]Completion,
	sqDoorbell: ^u32,
	cqDoorbell: ^u32,
	depth:      u32,
	qid:        u16,
	nsid:       u32,
	lbaSize:    u32,
}
