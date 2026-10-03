package ifs
import "core:mem"

DEFAULT_ROOT_LEN :: 25
IFS_IMPLICIT_ALLOCATOR: ^DiskAllocator = nil
SlotCount :: u64
#assert(size_of(SlotCount) % SLOT_ALIGN == 0)

init :: proc(dev: ^Device) -> Error {
	superblock, found := detect(dev) or_return

	if found do return nil
	root := make([]byte, DEFAULT_ROOT_LEN, context.temp_allocator)
	format(dev, root) or_return

	return nil

}
detect :: proc(dev: ^Device) -> (superblock: Superblock, found: bool, err: Error) {
	read_range(dev, 0, mem.ptr_to_bytes(&superblock)) or_return
	if superblock.magic != MAGIC_IFS do return {}, false, nil
	root := superblock.root
	if root.offset < u64(dev.blockSize) do return {}, false, .Corrupt
	if root.offset % u64(dev.blockSize) != 0 do return {}, false, .Corrupt
	if root.cap < size_of(Slot) || root.cap % size_of(Slot) != 0 do return {}, false, .Corrupt
	if !range_valid(dev, root.offset, root.cap) do return {}, false, .Corrupt
	return superblock, true, nil
}
ROOT_BLOCK_DEFAULT_COUNT :: 1
NAME_FILE_DEFAULT_BLOCK_COUNT :: 1
format :: proc(dev: ^Device, alloc: ^DiskAllocator = IFS_IMPLICIT_ALLOCATOR) -> Error {
	blockSize := u64(dev.blockSize)
	assert(blockSize >= size_of(Superblock))
	assert(blockSize >= size_of(HeaderOfNameEntry))
	assert(blockSize >= size_of(SlotCount) + size_of(Slot))


	nameFileBlock := disk_alloc(alloc, NAME_FILE_DEFAULT_BLOCK_COUNT) or_return
	names := Slot {
		offset = nameFileBlock * blockSize,
		cap    = NAME_FILE_DEFAULT_BLOCK_COUNT * blockSize,
	}
	nameFile, aErr := make([dynamic]byte, names.cap, context.temp_allocator)
	if aErr != nil do return .OutOfMemory
	write_range(dev, names.offset, nameFile[:]) or_return

	rootBlock := disk_alloc(alloc, ROOT_BLOCK_DEFAULT_COUNT) or_return
	root := Slot {
		offset = rootBlock * blockSize,
		cap    = ROOT_BLOCK_DEFAULT_COUNT * blockSize,
	}
	rootDir: []byte
	rootDir, aErr = make_aligned([]byte, root.cap, SLOT_ALIGN, context.temp_allocator)
	if aErr != nil do return .OutOfMemory
	(^SlotCount)(raw_data(rootDir))^ = 1
	(^Slot)(raw_data(rootDir[size_of(SlotCount):]))^ = names
	write_range(dev, root.offset, rootDir) or_return
	superblock := Superblock {
		magic = MAGIC_IFS,
		root  = root,
	}
	return write_range(dev, 0, mem.ptr_to_bytes(&superblock))
}
