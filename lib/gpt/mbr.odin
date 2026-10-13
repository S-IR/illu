package gpt
import "../shared"
MBR_SIGNATURE :: u16(0xAA55)
MBR_OS_TYPE_GPT_PROTECTIVE :: u8(0xEE)
MbrPartitionRecord :: struct #packed {
	bootIndicator: u8,
	startingChs:   [3]u8,
	osType:        u8,
	endingChs:     [3]u8,
	startingLba:   u32,
	sizeInLba:     u32,
}
#assert(size_of(MbrPartitionRecord) == 16)

Mbr :: struct #packed {
	bootCode:            [440]u8,
	uniqueDiskSignature: u32,
	unknown:             u16,
	partitions:          [4]MbrPartitionRecord,
	signature:           u16,
}
#assert(size_of(Mbr) == 512)
#assert(offset_of(Mbr, partitions) == 446)

protective_mbr :: proc(blockCount: u64) -> (mbr: Mbr, err: shared.Error) {
	if !shared.api_check(blockCount >= 2) do return {}, .InvalidAPICall
	mbr.signature = MBR_SIGNATURE
	mbr.partitions[0] = {
		startingChs = {0x00, 0x02, 0x00},
		osType      = MBR_OS_TYPE_GPT_PROTECTIVE,
		endingChs   = {0xff, 0xff, 0xff},
		startingLba = 1,
		sizeInLba   = u32(min(blockCount - 1, u64(max(u32)))),
	}

	return mbr, .None
}
