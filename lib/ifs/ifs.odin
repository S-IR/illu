package ifs
import "../nvme"
IFS_MAGIC :: u64(0xFAFAFEFE)


Device :: union {
	NvmeDevice,
}
// mount :: proc(d: ) {
//
// }
