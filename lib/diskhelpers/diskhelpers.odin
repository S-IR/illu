package diskhelpers
import "../nvme"
import "../shared"
import "base:intrinsics"
import "core:mem"

NvmeDisk :: struct {
	dev:   nvme.Device,
	queue: nvme.Queue,
	rings: NvmeRings,
}
NvmeRing :: struct {
	handle:  int,
	info:    nvme.QueueInfo,
	cqBytes: u64,
}
NvmeRings :: struct {
	authority: []byte,
	v:         []NvmeRing,
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
	if bytes > max(u64) - (shared.PAGE_SIZE - 1) do return {}, -1
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

disk_submit :: proc(
	disk: ^Disk,
	dps: ^[dynamic]DiskPending,
	op: nvme.IoOpcode,
	block: u64,
	buffer: []byte,
	prpList: []u64,
	fua: bool,
) -> shared.Error {
	for {
		pending: nvme.Pending
		err: shared.Error
		switch &d in disk.driver {
		case NvmeDisk:
			if op == .Flush {
				pending, err = nvme.queue_flush(&d.queue)
			} else {
				pending, err = nvme.queue_io(&d.queue, op, block, {buffer}, prpList, fua)
			}
		}
		if err == .None {
			if _, aErr := append(dps, pending); aErr == nil do return .None
			nvme.wait(pending, max(u64))
			err = .OutOfMemory
		}
		retry := err == .NvmeQueueFull && len(dps^) > 0
		waitErr := wait_all(dps^[:])
		clear(dps)
		if !retry do return err
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

disk_io :: proc(
	disk: ^Disk,
	dps: ^[dynamic]DiskPending,
	op: nvme.IoOpcode,
	blocks: []u64,
	bufs: [][]byte,
	fua := false,
) -> (
	err: shared.Error,
) {

	if !shared.assert(disk != nil) do return .InvalidAPICall
	if !shared.assert(dps != nil) do return .InvalidAPICall
	if !shared.assert(len(blocks) == len(bufs)) do return .InvalidAPICall
	defer if err != .None {
		wait_all(dps^[:])
		clear(dps)
	}

	if op == .Flush {
		if !shared.assert(len(bufs) == 0 && !fua) do return .InvalidAPICall
		return disk_submit(disk, dps, .Flush, 0, nil, nil, false)
	}

	for buf, i in bufs {
		blockCount := u64(len(buf)) / u64(disk.blockSize)
		if !shared.assert(len(buf) > 0) do return .InvalidAPICall
		if !shared.assert(len(buf) % int(disk.blockSize) == 0) do return .InvalidAPICall
		if !shared.assert(uintptr(raw_data(buf)) % 4 == 0) do return .InvalidAPICall
		if !shared.assert(blocks[i] <= disk.blockCount) do return .InvalidAPICall
		if !shared.assert(blockCount <= disk.blockCount - blocks[i]) do return .InvalidAPICall
	}
	switch &d in disk.driver {

	case NvmeDisk:
		listBytes := 0
		for buf in bufs {
			for off := 0; off < len(buf); off += int(d.queue.maxTransfer) {
				cutSlice := buf[off:min(off + int(d.queue.maxTransfer), len(buf))]
				listBytes += mem.align_forward_int(
					nvme.prp_list_len({cutSlice}) * size_of(u64),
					shared.PAGE_SIZE,
				)
			}
		}
		assert(listBytes % shared.PAGE_SIZE == 0)

		lists, aErr := make_aligned([]byte, listBytes, shared.PAGE_SIZE, context.temp_allocator)
		if aErr != nil do return .OutOfMemory
		listOff := 0
		for buf, i in bufs {
			for off := 0; off < len(buf); off += int(d.queue.maxTransfer) {
				cutSlice := buf[off:min(off + int(d.queue.maxTransfer), len(buf))]
				n := nvme.prp_list_len({cutSlice})
				prpList: []u64 = nil
				if n > 0 do prpList = mem.slice_ptr((^u64)(raw_data(lists[listOff:])), n)
				listOff += mem.align_forward_int(n * size_of(u64), shared.PAGE_SIZE)
				disk_submit(
					disk,
					dps,
					op,
					blocks[i] + u64(off) / u64(disk.blockSize),
					cutSlice,
					prpList,
					fua,
				) or_return
			}
		}
		assert(listOff == listBytes)
		return .None
	case:
		unreachable()
	}
}
