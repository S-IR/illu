package ifs
import "../shared"
import "core:encoding/endian"
IFS_MAGIC :: u64(0x5346_495f_554c_4c49)
IFS_MAGIC_OFFSET :: 0


is :: proc(partitionStart: []byte) -> bool {
	if !shared.api_check(len(partitionStart) >= (IFS_MAGIC_OFFSET + size_of(IFS_MAGIC))) {
		return false
	}
	return endian.unchecked_get_u64le(partitionStart[IFS_MAGIC_OFFSET:]) == IFS_MAGIC
}
init :: proc(firstBlock: u64, len: u64) {

}


// mount :: proc(d: ) {
//
// }
