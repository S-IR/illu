package pe

find_data_directory :: proc(
	data: []u8,
	optionalOffset, sizeOfOptionalHeader: u64,
	index: DataDirectoryIndex,
) -> (
	rva, size: u32,
) {
	if sizeOfOptionalHeader < DATA_DIRECTORY_OFFSET do return 0, 0

	countOffset := optionalOffset + NUMBER_OF_RVA_AND_SIZES_OFFSET
	if !has_range(data, countOffset, 4) do return 0, 0

	count := u64(read_u32(data, countOffset))
	if count <= u64(index) do return 0, 0

	dirOffset := optionalOffset + DATA_DIRECTORY_OFFSET + u64(index) * DATA_DIRECTORY_ENTRY_SIZE
	if dirOffset + DATA_DIRECTORY_ENTRY_SIZE > optionalOffset + sizeOfOptionalHeader do return 0, 0

	return read_u32(data, dirOffset), read_u32(data, dirOffset + 4)
}

read_cstr :: proc(data: []u8, offset: u64) -> (string, bool) {
	i := int(offset)
	if i < 0 || i >= len(data) do return "", false
	start := i
	for i < len(data) && data[i] != 0 do i += 1
	if i >= len(data) || i == start do return "", false
	return string(data[start:i]), true
}
