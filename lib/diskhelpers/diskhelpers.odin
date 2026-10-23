package diskhelpers
import "../alloc"
import "../nvme"
import "../shared"
import "base:intrinsics"
import "core:math"
import "core:mem"

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

disk_read_batch :: proc(
	disk: ^Disk,
	dps: ^[dynamic]DiskPending,
	blocks: []u64,
	bufs: [][]byte,
) -> (
	prpDma: u64,
	err: shared.Error,
) {
	if !shared.assert(disk != nil) do return 0, .InvalidAPICall
	if !shared.assert(dps != nil) do return 0, .InvalidAPICall
	if !shared.assert(len(blocks) == len(bufs)) do return 0, .InvalidAPICall

	for buf in bufs {
		if !shared.assert(len(buf) > 0) do return 0, .InvalidAPICall
		if !shared.assert(len(buf) % int(disk.blockSize) == 0) do return 0, .InvalidAPICall
		if !shared.assert(uintptr(raw_data(buf)) % shared.PAGE_SIZE == 0) do return 0, .InvalidAPICall


	}
	switch &d in disk.driver {

	case NvmeDisk:
		listBytes: u64 = 0
		for buf in bufs {
			for off := 0; off < len(buf); off += int(d.queue.maxTransfer) {
				cutSlice := buf[off:min(off + int(d.queue.maxTransfer), len(buf))]
				listBytes += u64(
					mem.align_forward_int(
						nvme.prp_list_len({cutSlice}) * size_of(u64),
						shared.PAGE_SIZE,
					),
				)
			}
		}

		assert(listBytes % shared.PAGE_SIZE == 0)
		if listBytes >= shared.PAGE_SIZE {
			prpDma = alloc.dma_pages(listBytes / shared.PAGE_SIZE) or_return
		}
		listOff: u64 = 0
		for buf, i in bufs {
			for off := 0; off < len(buf); off += int(d.queue.maxTransfer) {
				cutSlice := buf[off:min(off + int(d.queue.maxTransfer), len(buf))]
				n := nvme.prp_list_len({cutSlice})
				prpList: []u64 = nil
				if n > 0 do prpList = mem.slice_ptr((^u64)(uintptr(prpDma + listOff)), n)
				listOff += u64(mem.align_forward_int(n * size_of(u64), shared.PAGE_SIZE))
				disk_submit(
					disk,
					dps,
					.Read,
					blocks[i] + u64(off) / u64(disk.blockSize),
					cutSlice,
					prpList,
				) or_return

			}
		}
		assert(listOff == listBytes)
		return prpDma, .None
	case:
		unreachable()
	}

}
