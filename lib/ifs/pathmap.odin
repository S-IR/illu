package ifs
import "../shared"
import "core:hash/xxhash"
import "core:mem"
import "core:slice"
import "core:strings"
PathEntry :: struct #all_or_none {
	offset, cap: u64,
	slotOffset:  u64,
}

DirToScan :: struct {
	path: string,
	slot: Slot,
}


PathMap :: map[u128]PathEntry

path_hash :: proc(path: string) -> u128 {
	return u128(xxhash.XXH3_128_default(transmute([]byte)path))
}

HeaderOfNameEntry :: struct {
	slotIdx, nameLen: u64,
}
pathmap_scan_dir :: proc(
	dev: ^Device,
	pathmap: ^PathMap,
	path: string,
	dir: Slot,
	skipped: ^[dynamic]u64,
) -> Error {
	toScan := make([dynamic]DirToScan, context.temp_allocator)
	if _, err := append(&toScan, DirToScan{path = path, slot = dir}); err != nil do return .OutOfMemory


	dirBuf, aErr := make([dynamic]byte, dev.blockSize, context.temp_allocator)
	if aErr != nil do return .OutOfMemory
	namesBuf: [dynamic]byte
	namesBuf, aErr = make([dynamic]byte, dev.blockSize, context.temp_allocator)
	if aErr != nil do return .OutOfMemory

	for len(toScan) > 0 {
		next := pop(&toScan)
		if next.slot.offset == 0 || next.slot.cap == 0 do continue

		if next.slot.cap % size_of(Slot) != 0 do return .Corrupt


		fld, err := read_file_into(dev, next.slot, &dirBuf)
		if err != nil {
			if _, aErr = append(skipped, next.slot.offset); aErr != nil do return .OutOfMemory
			continue
		}

		assert(uintptr(raw_data(fld)) % SLOT_ALIGN == 0)
		fldSlots := slice.reinterpret([]Slot, fld)
		assert(len(fldSlots) > 0)
		namesFile := fldSlots[0]
		nameFile: []byte
		nameFile, err = read_file_into(dev, namesFile, &namesBuf)
		if err != nil {
			if _, aErr = append(skipped, next.slot.offset); aErr != nil do return .OutOfMemory
			continue
		}
		rest := nameFile


		for len(rest) >= size_of(HeaderOfNameEntry) {
			fileNameHeader := (^HeaderOfNameEntry)(raw_data(rest))^
			if fileNameHeader.slotIdx == 0 do break
			if fileNameHeader.slotIdx >= u64(len(fldSlots)) do return .Corrupt
			body := rest[size_of(HeaderOfNameEntry):]
			if fileNameHeader.nameLen > u64(len(body)) do return .Corrupt
			fileName := string(body[:fileNameHeader.nameLen])
			step := mem.align_forward_int(
				size_of(HeaderOfNameEntry) + int(fileNameHeader.nameLen),
				8,
			)
			rest = rest[min((step), len(rest)):]

			fileHeader := fldSlots[fileNameHeader.slotIdx]
			if fileHeader.offset == 0 || fileNameHeader.nameLen == 0 do continue

			fullFilePath := strings.concatenate({next.path, fileName}, context.temp_allocator)

			mapAllocPtr := map_insert(
				pathmap,
				path_hash(fullFilePath),
				PathEntry {
					slotOffset = fileNameHeader.slotIdx,
					cap = fileHeader.cap,
					offset = fileHeader.offset,
				},
			)
			if mapAllocPtr == nil do return .OutOfMemory

			isDir := strings.ends_with(fileName, "/")
			if isDir {
				_, aErr = append(&toScan, DirToScan{path = fullFilePath, slot = fileHeader})
				if aErr != nil do return .OutOfMemory
			}


		}

	}
	return .None
}


read_file_into :: proc(
	dev: ^Device,
	file: Slot,
	buf: ^[dynamic]byte,
) -> (
	data: []byte,
	err: Error,
) {
	if !range_valid(dev, file.offset, file.cap) do return nil, .Corrupt
	size := int(file.cap)
	if size > len(buf) {
		if resize(buf, size) != nil do return nil, .OutOfMemory
	}
	data = buf[:size]
	read_range(dev, file.offset, data) or_return
	return data, nil
}
