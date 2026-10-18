package diskhelpers

import "../nvme"
import "../shared"
import "base:intrinsics"

NvmeDisk :: struct {
	dev:   nvme.Device,
	queue: nvme.Queue,
}
DiskDriver :: union {
	NvmeDisk,
}
Disk :: struct {
	driver:     DiskDriver,
	blockCount: u64,
	base:       u64,
	blockSize:  u32,
}


disk_new :: proc(
	driver: DiskDriver,
	blockSize: u32,
	blockCount: u64,
	startingMadeUpAddr: u64,
) -> (
	disk: Disk,
	used: int,
) {
	assert(driver != nil)
	assert(blockSize > 0)


	if blockCount > (max(u64) / u64(blockSize)) do return {}, -1
	bytes, overflown := intrinsics.overflow_mul(blockCount, u64(blockSize))
	if overflown do return {}, -1
	size := (bytes + shared.PAGE_SIZE - 1) & ~u64(shared.PAGE_SIZE - 1)
	if size > max(u64) - startingMadeUpAddr do return {}, -1
	if size > u64((max(int))) do return {}, -1


	return Disk {
		driver = driver,
		base = startingMadeUpAddr,
		blockCount = blockCount,
		blockSize = blockSize,
	}, int(size)
}

DiskPending :: union {
	nvme.Pending,
}

disk_io :: proc(
	disk: ^Disk,
	op: nvme.IoOpcode,
	block: u64,
	buffer: []byte,
	prpList: []u64 = nil,
) -> (
	dp: DiskPending,
	err: shared.Error,
) {
	if !shared.assert(disk != nil) do return {}, .InvalidAPICall
	switch op {
	case .Flush:
		if !shared.assert(len(buffer) == 0) do return {}, .InvalidAPICall
		if !shared.assert(block == 0) do return {}, .InvalidAPICall
		if !shared.assert(len(prpList) == 0) do return {}, .InvalidAPICall

	case .Read, .Write:
		if !shared.assert(len(buffer) != 0) do return {}, .InvalidAPICall

	}


	switch &d in disk.driver {
	case NvmeDisk:
		if op == .Flush do return nvme.queue_flush(&d.queue)
		if !shared.assert(len(buffer) % int(d.dev.lbaSize) == 0) do return {}, .InvalidAPICall

		blockCount := len(buffer) / int(d.dev.lbaSize)
		if !shared.assert(block <= disk.blockCount) do return {}, .InvalidAPICall
		if !shared.assert(u64(blockCount) <= disk.blockCount - block) do return {}, .InvalidAPICall
		return nvme.queue_io(&d.queue, op, block, {buffer}, prpList)

	}
	unreachable()
}
disk_submit :: proc(
	disk: ^Disk,
	dps: ^[dynamic]DiskPending,
	op: nvme.IoOpcode,
	block: u64,
	buffer: []byte,
	prpList: []u64 = nil,
) -> shared.Error {
	if !shared.assert(dps != nil) do return .InvalidAPICall
	for {
		dp, err := disk_io(disk, op, block, buffer, prpList)
		if err == .None {
			append(dps, dp)
			return .None
		}
		if err != .NvmeQueueFull || len(dps^) == 0 do return err
		waitErr := wait_all(dps^[:])
		clear(dps)
		if waitErr != .None do return waitErr
	}
}
wait :: proc(dp: DiskPending) -> shared.Error {
	switch p in dp {
	case nvme.Pending:
		return nvme.wait(p, max(u64))
	}
	unreachable()
}
wait_all :: proc(dps: []DiskPending) -> (err: shared.Error) {
	for dp in dps {
		waitErr := wait(dp)
		if err == .None do err = waitErr
	}
	return err
}
