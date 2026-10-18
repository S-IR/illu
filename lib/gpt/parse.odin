package gpt
import "../shared"
import "core:hash"
import "core:math/bits"
import "core:mem"
import "core:slice"
parse_header :: proc(data: []byte) -> (h: Header, err: shared.Error) {
	if !shared.assert(len(data) >= 512) do return {}, .InvalidAPICall
	h = (^Header)(raw_data(data))^
	if h.signature != SIGNATURE do return {}, .GptNotGpt
	if h.headerSize < size_of(Header) || int(h.headerSize) > len(data) do return {}, .Corrupt

	crc32Offset :: offset_of(Header, headerCrc32)
	hashRes := hash.crc32(data[:crc32Offset])
	fourZeroBytes := [4]u8{}
	hashRes = hash.crc32(fourZeroBytes[:], hashRes)
	hashRes = hash.crc32(data[crc32Offset + size_of(u32):h.headerSize], hashRes)
	if hashRes != h.headerCrc32 do return {}, .Corrupt

	if h.firstUsableLba > h.lastUsableLba do return {}, .Corrupt
	if h.reserved != 0 do return {}, .Corrupt
	if h.myLba != 1 do return {}, .Corrupt
	if h.partitionEntrySize < size_of(PartitionEntry) || h.partitionEntrySize % size_of(PartitionEntry) != 0 do return {}, .Corrupt
	if !bits.is_power_of_two(h.partitionEntrySize / size_of(PartitionEntry)) do return {}, .Corrupt
	return h, .None
}
parse_entries :: proc(h: Header, data: []byte) -> (out: [dynamic]Partition, err: shared.Error) {
	arrayBytes := u64(h.partitionEntryCount) * u64(h.partitionEntrySize)
	if !shared.assert(len(data) >= int(arrayBytes)) do return nil, .InvalidAPICall
	crc32 := hash.crc32(data[:arrayBytes])
	if crc32 != h.partitionEntryArrayCrc32 do return out, .Corrupt

	out = make([dynamic]Partition, 0, h.partitionEntryCount)
	defer if err != .None do delete(out)

	for i in 0 ..< h.partitionEntryCount {
		off := u64(i) * u64(h.partitionEntrySize)
		entry, ok := slice.to_type(data[off:], PartitionEntry)
		assert(ok)

		if entry.typeGuid == {} do continue
		if entry.firstLba > entry.lastLba do return out, .Corrupt
		if entry.firstLba < h.firstUsableLba do return out, .Corrupt
		if entry.lastLba > h.lastUsableLba do return out, .Corrupt
		for p in out {
			if entry.firstLba <= p.lastLba && p.firstLba <= entry.lastLba do return out, .Corrupt
		}
		append(
			&out,
			Partition {
				typeGuid = entry.typeGuid,
				firstLba = entry.firstLba,
				lastLba = entry.lastLba,
			},
		)

	}
	return out, .None
}

header_new :: proc(
	blockCount: u64,
	blockSize: u32,
	entryCount: u32,
	diskGuid: Guid,
) -> (
	header: Header,
	err: shared.Error,
) {
	if !shared.assert(blockSize >= 512) do return {}, .InvalidAPICall
	if !shared.assert(u64(entryCount) * size_of(PartitionEntry) >= 16384) do return {}, .InvalidAPICall

	entryBlocks: u64 =
		(u64(entryCount) * size_of(PartitionEntry) + u64(blockSize) - 1) / u64(blockSize)
	if !shared.assert(blockCount >= 2 * entryBlocks + 4) do return {}, .InvalidAPICall


	return {
			signature = SIGNATURE,
			revision = 0x0001_0000,
			headerSize = size_of(Header),
			myLba = HEADER_BLOCK_LOCATION,
			alternateLba = blockCount - 1,
			diskGuid = diskGuid,
			partitionEntryLba = 2,
			partitionEntryCount = entryCount,
			partitionEntrySize = size_of(PartitionEntry),
			firstUsableLba = 2 + entryBlocks,
			lastUsableLba = (blockCount - 1) - entryBlocks - 1,
		},
		.None

}

entries_write :: proc(h: Header, entries: []PartitionEntry, out: []byte) -> (u32, shared.Error) {
	if !shared.assert(h.partitionEntrySize >= size_of(PartitionEntry)) do return {}, .InvalidAPICall
	if !shared.assert(len(entries) <= int(h.partitionEntryCount)) do return {}, .InvalidAPICall
	arrayBytes := int(h.partitionEntryCount) * int(h.partitionEntrySize)
	if !shared.assert(len(out) >= (arrayBytes)) do return {}, .InvalidAPICall

	for entry, i in entries {
		if !shared.assert(entry.typeGuid != {}) do return {}, .InvalidAPICall
		if !shared.assert(entry.uniqueGuid != {}) do return {}, .InvalidAPICall
		if !shared.assert(entry.firstLba <= entry.lastLba) do return {}, .InvalidAPICall
		if !shared.assert(entry.firstLba >= h.firstUsableLba) do return {}, .InvalidAPICall
		if !shared.assert(entry.lastLba <= h.lastUsableLba) do return {}, .InvalidAPICall
		for p in entries[:i] {
			if !shared.assert(entry.firstLba > p.lastLba || p.firstLba > entry.lastLba) do return {}, .InvalidAPICall
		}
	}
	mem.zero_slice(out)
	for entry, i in entries {
		copy(out[i * int(h.partitionEntrySize):], mem.any_to_bytes(entry))

	}
	return hash.crc32(out[:arrayBytes]), .None
}
