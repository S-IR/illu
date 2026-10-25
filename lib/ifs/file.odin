package ifs
import "../alloc"
import "../diskhelpers"
import "../shared"
import "../syscalls"
import "base:intrinsics"
import "core:mem"
import "core:slice"
Slot :: struct {
	offset, cap: u64,
}
#assert(size_of(Slot) == 16)
DirHeader :: struct {
	count, reserved: u64,
}
#assert(size_of(DirHeader) == 16)

NameFileHeader :: struct {
	refLen, heapOffset: u64,
}
#assert(size_of(NameFileHeader) == 16)

NameRef :: struct {
	slotIdx, nameOffset: u64,
}
#assert(size_of(NameRef) == 16)
NameRecord :: struct #packed {
	nameLen: u64,
}
#assert(size_of(NameRecord) == 8)
ref_name :: proc(buf: []byte, ref: NameRef) -> string {
	assert(ref.nameOffset <= u64(len(buf)) - size_of(NameRecord))
	record := (^NameRecord)(raw_data(buf[ref.nameOffset:]))^
	nameStart := ref.nameOffset + size_of(NameRecord)
	return string(buf[nameStart:][:record.nameLen])
}
name_file_parse :: proc(buf: []byte) -> (refs: []NameRef, err: shared.Error) {
	if !shared.assert(len(buf) >= size_of(NameFileHeader)) do return nil, .InvalidAPICall
	bufLen := u64(len(buf))
	header := (^NameFileHeader)(raw_data(buf))^
	if header.refLen > (bufLen - size_of(NameFileHeader)) / size_of(NameRef) do return nil, .Corrupt
	refsEnd := size_of(NameFileHeader) + header.refLen * size_of(NameRef)
	if header.heapOffset < refsEnd do return nil, .Corrupt
	if header.heapOffset > bufLen do return nil, .Corrupt

	refs = mem.slice_ptr((^NameRef)(raw_data(buf[size_of(NameFileHeader):])), int(header.refLen))

	for ref, i in refs {
		if ref.nameOffset < header.heapOffset do return nil, .Corrupt
		if ref.nameOffset > bufLen - size_of(NameRecord) do return nil, .Corrupt
		record := (^NameRecord)(raw_data(buf[ref.nameOffset:]))^
		if record.nameLen == 0 do return nil, .Corrupt
		if record.nameLen > bufLen - ref.nameOffset - size_of(NameRecord) do return nil, .Corrupt
		if i != 0 && ref_name(buf, refs[i - 1]) >= ref_name(buf, ref) do return nil, .Corrupt
	}
	return refs, .None
}

ESCAPE_CHAR :: '\\'
FOLDER_ENDING :: '/'

is_dir_name :: proc(name: string) -> bool {
	if len(name) == 0 do return false
	if name[len(name) - 1] != FOLDER_ENDING do return false

	countOfEscapeChars := 0
	for i := len(name) - 2; i >= 0 && name[i] == ESCAPE_CHAR; i -= 1 do countOfEscapeChars += 1
	return countOfEscapeChars % 2 == 0
}
name_insert :: proc(buf: []byte, slotIdx: u64, name: string) -> shared.Error {
	if !shared.assert(len(name) > 0) do return .InvalidAPICall
	if !shared.assert(slotIdx != 0) do return .InvalidAPICall

	refs := name_file_parse(buf) or_return


	lo, hit := name_find(buf, refs, name)
	if hit do return .FsNameAlreadyExists

	assert(lo <= len(refs))
	header := (^NameFileHeader)(raw_data(buf))^
	assert(header.refLen == u64(len(refs)))

	refsEnd := size_of(NameFileHeader) + header.refLen * size_of(NameRef)
	assert(refsEnd <= header.heapOffset)
	freeSpace := header.heapOffset - refsEnd

	StaticNameByteRequirement :: size_of(NameRef) + size_of(NameRecord)
	if freeSpace < StaticNameByteRequirement do return .FsDiskFileFull
	if u64(len(name)) > freeSpace - StaticNameByteRequirement do return .FsDiskFileFull

	newOffset := header.heapOffset - size_of(NameRecord) - u64(len(name))
	assert((refsEnd + size_of(NameRef)) <= newOffset)
	(^NameRecord)(raw_data(buf[newOffset:]))^ = {u64(len(name))}

	copy(buf[newOffset + size_of(NameRecord):], name)
	header.heapOffset = newOffset

	refsSlicePlusOne := mem.slice_ptr(
		(^NameRef)(raw_data(buf[size_of(NameFileHeader):])),
		len(refs) + 1,
	)

	copy(refsSlicePlusOne[lo + 1:], refs[lo:len(refs)])
	refsSlicePlusOne[lo] = {slotIdx, newOffset}
	header.refLen += 1
	(^NameFileHeader)(raw_data(buf))^ = header
	return .None
}
name_remove :: proc(buf: []byte, name: string) -> (slotIdx: u64, err: shared.Error) {
	if !shared.assert(len(name) > 0) do return 0, .InvalidAPICall

	refs := name_file_parse(buf) or_return
	header := (^NameFileHeader)(raw_data(buf))

	idx, hit := name_find(buf, refs, name)
	if !hit do return 0, .NotFound


	slotIdx = refs[idx].slotIdx
	oldOffset := refs[idx].nameOffset
	recLen := size_of(NameRecord) + u64(len(name))

	copy(refs[idx:], refs[idx + 1:])
	refs[len(refs) - 1] = {}
	header.refLen -= 1

	copy(buf[header.heapOffset + recLen:oldOffset + recLen], buf[header.heapOffset:oldOffset])
	slice.zero(buf[header.heapOffset:][:recLen])
	header.heapOffset += recLen
	for &ref in refs[:header.refLen] {
		if ref.nameOffset < oldOffset do ref.nameOffset += recLen
	}
	return slotIdx, .None
}

dir_parse :: proc(buf: []byte) -> (header: DirHeader, slots: []Slot, err: shared.Error) {
	if len(buf) < size_of(DirHeader) + 2 * size_of(Slot) do return {}, nil, .Corrupt

	header = (^DirHeader)(raw_data(buf))^
	if header.reserved != 0 do return {}, nil, .Corrupt
	if header.count == 0 do return {}, nil, .Corrupt
	capSlots := (len(buf) - size_of(DirHeader)) / size_of(Slot)
	if header.count > u64(capSlots) do return {}, nil, .Corrupt

	slots = mem.slice_ptr((^Slot)(raw_data(buf[size_of(DirHeader):])), int(header.count))
	return header, slots, .None
}
dir_slot_set :: proc(buf: []byte, slot: Slot) -> (slotIdx: u64, err: shared.Error) {
	if !shared.assert(slot.cap > 0) do return 0, .InvalidAPICall
	if !shared.assert(slot.offset > 0) do return 0, .InvalidAPICall

	_, slots := dir_parse(buf) or_return
	capSlots := (len(buf) - size_of(DirHeader)) / size_of(Slot)
	for i in 1 ..< len(slots) {
		if slots[i] != {} do continue
		slots[i] = slot
		return u64(i), .None
	}

	appendIdx := len(slots)
	if appendIdx >= capSlots do return 0, .FsDirFull
	(^Slot)(raw_data(buf[size_of(DirHeader) + appendIdx * size_of(Slot):]))^ = slot
	(^DirHeader)(raw_data(buf)).count += 1
	return u64(appendIdx), .None
}
dir_slot_clear :: proc(buf: []byte, slotIdx: u64) -> shared.Error {
	header, slots := dir_parse(buf) or_return
	if !shared.assert(slotIdx > 0 && slotIdx < header.count) do return .InvalidAPICall
	if !shared.assert(slots[slotIdx] != {}) do return .InvalidAPICall

	slots[slotIdx] = {}
	count := header.count
	for count > 1 && slots[count - 1] == {} do count -= 1
	(^DirHeader)(raw_data(buf)).count = count
	return .None
}
slots_read :: proc(
	disk: ^diskhelpers.Disk,
	partStart: u64,
	slots: []Slot,
	dps: ^[dynamic]diskhelpers.DiskPending,
) -> (
	bufs: [][]byte,
	err: shared.Error,
) {
	if !shared.assert(disk != nil) do return nil, .InvalidAPICall
	if !shared.assert(dps != nil) do return nil, .InvalidAPICall
	defer if err != .None {
		diskhelpers.wait_all(dps^[:])
		clear(dps)
	}

	blocks, aErr := make([]u64, len(slots), context.temp_allocator)
	if aErr != .None do return nil, .OutOfMemory
	bufs, aErr = make([][]byte, len(slots), context.temp_allocator)
	if aErr != .None do return nil, .OutOfMemory
	for slot, i in slots {
		blocks[i] = partStart + slot.offset / u64(disk.blockSize)
		bufs[i], aErr = make_aligned([]byte, slot.cap, shared.PAGE_SIZE, context.temp_allocator)
		if aErr != .None do return nil, .OutOfMemory
	}

	diskhelpers.disk_io(disk, dps, .Read, blocks, bufs) or_return
	return bufs, .None
}
dirs_read :: proc(
	disk: ^diskhelpers.Disk,
	partStart, partBlocks: u64,
	dirSlots: []Slot,
) -> (
	dirBufs: [][]byte,
	nameBufs: [][]byte,
	err: shared.Error,
) {
	if !shared.assert(disk != nil) do return nil, nil, .InvalidAPICall
	if !shared.assert(len(dirSlots) > 0) do return nil, nil, .InvalidAPICall

	dps := make([dynamic]diskhelpers.DiskPending, context.temp_allocator)
	dirBufs = slots_read(disk, partStart, dirSlots, &dps) or_return
	diskhelpers.wait_all(dps[:]) or_return
	clear(&dps)

	nameSlots, aErr := make([dynamic]Slot, 0, len(dirBufs), context.temp_allocator)
	if aErr != nil do return nil, nil, .OutOfMemory
	named: [dynamic]int
	named, aErr = make([dynamic]int, 0, len(dirBufs), context.temp_allocator)
	if aErr != nil do return nil, nil, .OutOfMemory
	nameBufs, aErr = make([][]byte, len(dirBufs), context.temp_allocator)
	if aErr != nil do return nil, nil, .OutOfMemory
	for buf, i in dirBufs {
		_, slots := dir_parse(buf) or_return
		_, extentErr := slot_extent(slots[0], u64(disk.blockSize), partBlocks)
		if extentErr == .Corrupt do continue
		if extentErr != .None do return nil, nil, extentErr
		append(&nameSlots, slots[0])
		append(&named, i)
	}
	if len(nameSlots) == 0 do return dirBufs, nameBufs, .None

	readBufs := slots_read(disk, partStart, nameSlots[:], &dps) or_return
	diskhelpers.wait_all(dps[:]) or_return
	for d, j in named do nameBufs[d] = readBufs[j]
	return dirBufs, nameBufs, .None
}
name_find :: proc(buf: []byte, refs: []NameRef, name: string) -> (idx: int, hit: bool) {
	assert(len(name) > 0)
	lo, hi: int = 0, len(refs)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		midName := ref_name(buf, refs[mid])
		if midName == name do return mid, true
		if midName < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	assert(lo <= len(refs))
	return lo, false
}
