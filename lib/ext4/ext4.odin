package ext4
import "../shared"
import "core:encoding/endian"
EXT4_MAGIC_OFFSET :: 1080
EXT4_MAGIC: u16 : 0xEF53
is :: proc(partitionStart: []byte) -> bool {
	if !shared.assert(len(partitionStart) >= EXT4_MAGIC_OFFSET + size_of(EXT4_MAGIC)) {
		return false
	}
	return endian.unchecked_get_u16le(partitionStart[EXT4_MAGIC_OFFSET:]) == EXT4_MAGIC
}
