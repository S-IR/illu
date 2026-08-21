#+test
package pe

import "core:testing"

put_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset + 0] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

put_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset + 0] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

put_u64 :: proc(data: []u8, offset: int, value: u64) {
	put_u32(data, offset, u32(value))
	put_u32(data, offset + 4, u32(value >> 32))
}

make_test_pe :: proc() -> []u8 {
	data := make([]u8, 0x800)
	put_u16(data, 0x00, IMAGE_DOS_SIGNATURE)
	put_u32(data, int(DOS_PE_OFFSET), 0x80)
	put_u32(data, 0x80, IMAGE_NT_SIGNATURE)

	coff := 0x84
	put_u16(data, coff + 0, IMAGE_FILE_MACHINE_AMD64)
	put_u16(data, coff + 2, 2)
	put_u16(data, coff + 16, 0xF0)

	optional := coff + 20
	put_u16(data, optional + 0, IMAGE_NT_OPTIONAL_HDR64_MAGIC)
	put_u32(data, optional + 16, 0x1010)
	put_u64(data, optional + 24, 0x140000000)
	put_u32(data, optional + 32, 0x1000)
	put_u32(data, optional + 36, 0x200)
	put_u32(data, optional + 56, 0x3000)
	put_u32(data, optional + 60, 0x400)

	sections := optional + 0xF0
	data[sections + 0] = '.'
	data[sections + 1] = 't'
	data[sections + 2] = 'e'
	data[sections + 3] = 'x'
	data[sections + 4] = 't'
	put_u32(data, sections + 8, 0x30)
	put_u32(data, sections + 12, 0x1000)
	put_u32(data, sections + 16, 0x200)
	put_u32(data, sections + 20, 0x400)
	put_u32(data, sections + 36, u32(SectionCharacteristic.MemoryExecute) | u32(SectionCharacteristic.MemoryRead))

	second := sections + 40
	data[second + 0] = '.'
	data[second + 1] = 'd'
	data[second + 2] = 'a'
	data[second + 3] = 't'
	data[second + 4] = 'a'
	put_u32(data, second + 8, 0x10)
	put_u32(data, second + 12, 0x2000)
	put_u32(data, second + 16, 0x200)
	put_u32(data, second + 20, 0x600)
	put_u32(data, second + 36, u32(SectionCharacteristic.MemoryRead) | u32(SectionCharacteristic.MemoryWrite))

	return data
}

@(test)
test_parse_pe32_plus :: proc(t: ^testing.T) {
	data := make_test_pe()
	defer delete(data)

	image, err := parse(data)
	testing.expect(t, err == .None)
	testing.expect(t, image.machine == IMAGE_FILE_MACHINE_AMD64)
	testing.expect(t, image.sectionCount == 2)
	testing.expect(t, image.entryRva == 0x1010)
	testing.expect(t, image.entry == 0x140001010)
	testing.expect(t, len(image.sections) == 2)
	testing.expect(t, len(image.pages) == 2)
	testing.expect(t, image.pages[0].base == 0x1000)
	testing.expect(t, image.pages[0].end == 0x2000)
	testing.expect(t, page_is_executable(image.pages[0]))
	testing.expect(t, !page_is_executable(image.pages[1]))
	delete(image.sections)
	delete(image.pages)
}

@(test)
test_rejects_bad_offsets :: proc(t: ^testing.T) {
	data := make_test_pe()
	defer delete(data)
	put_u32(data, int(DOS_PE_OFFSET), 0xFFFF_FFF0)
	image, err := parse(data)
	testing.expect(t, err == .TooSmall)
	delete(image.sections)
	delete(image.pages)

	delete(data)
	data = make_test_pe()
	put_u32(data, 0x80 + 4 + 20 + 16, 0x2FFF)
	image, err = parse(data)
	testing.expect(t, err == .InvalidEntryPoint)
	delete(image.sections)
	delete(image.pages)
}

@(test)
test_rejects_non_executable_entry :: proc(t: ^testing.T) {
	data := make_test_pe()
	defer delete(data)
	put_u32(data, 0x80 + 4 + 20 + 16, 0x2010)
	image, err := parse(data)
	testing.expect(t, err == .InvalidEntryPoint)
	delete(image.sections)
	delete(image.pages)
}
