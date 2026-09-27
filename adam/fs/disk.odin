package fs


DiskDriver :: union {
	^Nvme,
}

Disk :: struct {
	driver:     DiskDriver,
	blockSize:  u32,
	blockCount: u64,
}
disks: [dynamic]Disk
