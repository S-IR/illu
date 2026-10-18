package ifs
import "../shared"
import "core:encoding/endian"
IFS_MAGIC :: u64(0x5346_495f_554c_4c49)
IFS_MAGIC_OFFSET :: 0

Superblock :: struct {
	magic: u64,
	root:  Slot,
}
#assert(size_of(Superblock) == 24)
#assert(ROOT_DIR_DEFAULT_CAP <= shared.PAGE_SIZE && NAME_FILE_DEFAULT_CAP <= shared.PAGE_SIZE)
ROOT_DIR_DEFAULT_CAP :: shared.PAGE_SIZE
NAME_FILE_DEFAULT_CAP :: shared.PAGE_SIZE

is :: proc(partitionStart: []byte) -> bool {
	if !shared.assert(len(partitionStart) >= (IFS_MAGIC_OFFSET + size_of(IFS_MAGIC))) {
		return false
	}
	return endian.unchecked_get_u64le(partitionStart[IFS_MAGIC_OFFSET:]) == IFS_MAGIC
}
