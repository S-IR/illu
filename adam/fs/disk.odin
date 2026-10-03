package fs
import "../../lib/shared"
import "../../lib/spinlock"
import "../gs"
DiskDriver :: union {
	^Nvme,
}

Disk :: struct {
	driver:     DiskDriver,
	blockCount: u64,
	base:       u64,
	blockSize:  u32,
}
disks: [dynamic]Disk

disk_add :: proc(driver: DiskDriver, blockSize: u32, blockCount: u64) -> bool {
	assert(driver != nil)
	assert(blockSize > 0)
	spinlock.lock(&gs.nextMadeUpAddr.lock)
	defer spinlock.unlock(&gs.nextMadeUpAddr.lock)


	if blockCount > max(u64) / u64(blockSize) do return false
	bytes := blockCount * u64(blockSize)
	if bytes > max(u64) - shared.PAGE_SIZE do return false

	size := (bytes + shared.PAGE_SIZE - 1) & ~u64(shared.PAGE_SIZE - 1)

	disk := Disk {
		driver     = driver,
		base       = gs.nextMadeUpAddr.v,
		blockCount = blockCount,
		blockSize  = blockSize,
	}
	if size > max(u64) - gs.nextMadeUpAddr.v do return false

	if _, err := append(&disks, disk); err != nil do return false

	gs.nextMadeUpAddr.v += size
	return true
}
