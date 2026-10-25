package ifs
import "../diskhelpers"
import "../shared"
import "../syscalls"

import "core:hash/xxhash"

PathEntry :: struct {
	slot:    Slot,
	slotIdx: u64,
}

Pathmap :: map[u128]PathEntry
path_key :: proc(path: string) -> u128 {
	return xxhash.XXH3_128_default(transmute([]u8)path)
}

path_split :: proc(path: string) -> (parent, name: string) {
	assert(len(path) > 1)
	assert(path[0] == '/')

	for i := len(path) - 2; i >= 0; i -= 1 {
		if !is_dir_name(path[:i + 1]) do continue
		parent, name = path[:i + 1], path[i + 1:]
		assert(len(name) > 0)
		return
	}
	unreachable()
}
path_lookup :: proc(
	pathmap: ^Pathmap,
	disk: ^diskhelpers.Disk,
	partStart, partBlocks: u64,
	path: string,
) -> (
	entry: PathEntry,
	err: shared.Error,
) {
	if !shared.assert(pathmap != nil && disk != nil) do return {}, .InvalidAPICall
	if !shared.assert(len(path) > 0 && path[0] == '/') do return {}, .InvalidAPICall

	if cached, ok := pathmap[path_key(path)]; ok do return cached, .None
	if path == "/" do return {}, .NotFound
	parent, name := path_split(path)
	parentEntry := path_lookup(pathmap, disk, partStart, partBlocks, parent) or_return


	dirBufs, nameBufs := dirs_read(
		disk,
		partStart,
		partBlocks,
		{parentEntry.slot},
	) or_return
	_, dirSlots := dir_parse(dirBufs[0]) or_return
	if nameBufs[0] == nil do return {}, .NotFound
	refs, parseErr := name_file_parse(nameBufs[0])
	if parseErr == .Corrupt do return {}, .NotFound
	if parseErr != .None do return {}, parseErr

	idx, hit := name_find(nameBufs[0], refs, name)
	if !hit do return {}, .NotFound

	ref := refs[idx]
	if ref.slotIdx == 0 || ref.slotIdx >= u64(len(dirSlots)) do return {}, .Corrupt
	slot := dirSlots[ref.slotIdx]
	if slot == {} do return {}, .Corrupt
	_ = slot_extent(slot, u64(disk.blockSize), partBlocks) or_return
	entry = {slot, ref.slotIdx}

	if map_insert(pathmap, path_key(path), entry) == nil do return {}, .OutOfMemory
	return entry, .None
}
