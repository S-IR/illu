package fs


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
