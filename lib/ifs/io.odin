package ifs

import "../alloc"
import "../diskhelpers"
import "../gpt"
import "../nvme"
import "../shared"
import "../syscalls"
import "base:intrinsics"
import "core:hash"
import "core:mem"

files_io :: proc(
	disk: ^diskhelpers.Disk,
	partStart: u64,
	op: nvme.IoOpcode,
	slots: []Slot,
	offsets: []u64,
	bufs: [][]byte,
	fua: bool,
	dps: ^[dynamic]diskhelpers.DiskPending,
) -> (
	err: shared.Error,
) {
	if !shared.assert(disk != nil) do return .InvalidAPICall
	if !shared.assert(dps != nil) do return .InvalidAPICall
	defer if err != .None {
		diskhelpers.wait_all(dps^[:]); clear(dps)
	}

	if !shared.assert(len(slots) == len(offsets)) do return .InvalidAPICall
	if !shared.assert(len(bufs) == len(offsets)) do return .InvalidAPICall

	blockSize := u64(disk.blockSize)
	blocks, aErr := make([]u64, len(slots), context.temp_allocator)
	if aErr != .None do return .OutOfMemory

	for i in 0 ..< len(offsets) {
		bufLen := u64(len(bufs[i]))

		if !shared.assert(offsets[i] % blockSize == 0) do return .InvalidAPICall
		if !shared.assert(bufLen <= slots[i].cap && offsets[i] <= slots[i].cap - bufLen) do return .FsOutOfRange
		blocks[i] = partStart + (slots[i].offset + offsets[i]) / blockSize
	}
	return diskhelpers.disk_io(disk, dps, op, blocks, bufs, fua)
}
