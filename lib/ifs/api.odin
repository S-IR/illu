package ifs

import "core:mem"
//
// read_file :: proc(
// 	dev: ^Device,
// 	pathMap: PathMap,
// 	path: string,
// ) -> (
// 	file: [dynamic]byte,
// 	aErr: mem.Allocator_Error,
// ) {
// 	slot, ok := pathMap[path_hash(path)]
// 	if !ok do return nil, .None
// 	file = make([dynamic]byte, 0, slot.cap) or_return
// 	defer if aErr != nil {
// 		delete(file)
// 		file = nil
// 	}
//
// 	read_file_into(dev, )
// }
