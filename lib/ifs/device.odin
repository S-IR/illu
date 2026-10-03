package ifs
import "../nvme"


IfsError :: enum {
	None,
	OutOfRange,
	DiskTooSmall,
	DiskFull,
	Corrupt,
	DirFull,
	OutOfMemory,
}
RamDisk :: struct {
	bytes: []u8,
}

Backend :: union #no_nil {
	^RamDisk,
	^nvme.Queue,
}
Device :: struct {
	backend:    Backend,
	blockCount: u64,
	blockSize:  u32,
}
Direction :: enum u8 {
	Read,
	Write,
}
BlockError :: enum u8 {
	None,
	OutOfRange,
}
DeviceError :: union #shared_nil {
	BlockError,
	nvme.IoError,
}

DevicePending :: union {
	nvme.Pending,
}


@(private)
ram_block :: proc(dev: ^Device, disk: ^RamDisk, block: u64) -> []u8 {
	assert(u64(len(disk.bytes)) == dev.blockCount * u64(dev.blockSize))
	return disk.bytes[block * u64(dev.blockSize):][:dev.blockSize]
}
Error :: union #shared_nil {
	IfsError,
	DeviceError,
}
device_submit :: proc(
	dev: ^Device,
	op: nvme.IoOpcode,
	block: u64,
	buf: []byte,
) -> (
	pending: DevicePending,
	err: Error,
) {
	assert(op == .Read || op)
}
