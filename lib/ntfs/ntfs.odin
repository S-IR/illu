package ntfs
import "../shared"
NTFS_MAGIC_OFFSET :: 3
NTFS_MAGIC :: "NTFS    "
is :: proc(partitionStart: []byte) -> bool {
	if !shared.assert(len(partitionStart) >= NTFS_MAGIC_OFFSET + len(NTFS_MAGIC)) {
		return false
	}
	return string(partitionStart[NTFS_MAGIC_OFFSET:][:len(NTFS_MAGIC)]) == NTFS_MAGIC
}
