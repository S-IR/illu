package ifs
import "../shared"
import "core:mem"
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
CHUNK_LINK :: "|/"
FOLDER_ENDING :: '/'

is_dir_name :: proc(name: string) -> bool {
	if len(name) == 0 do return false
	if name[len(name) - 1] != FOLDER_ENDING do return false

	countOfEscapeChars := 0
	for i := len(name) - 2; i >= 0 && name[i] == ESCAPE_CHAR; i -= 1 do countOfEscapeChars += 1
	return countOfEscapeChars % 2 == 0
}
