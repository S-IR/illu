package ifs
import "core:strings"
MAGIC_IFS :: u64(0x5346_495f_554c_4c49)

Superblock :: struct {
	magic: u64,
	root:  Slot,
}

Slot :: struct {
	offset, cap: u64,
}

SLOT_ALIGN :: 8
#assert(size_of(Slot) == 16)
#assert(size_of(Superblock) == 24)
#assert(size_of(Slot) % SLOT_ALIGN == 0)

name_is_dir :: proc(name: string) -> bool {
	assert(len(name) > 0)
	if !strings.has_suffix(name, "/") do return false
	body := name[:len(name) - 1]
	return (len(body) - len(strings.trim_right(body, "\\"))) % 2 == 0
}
