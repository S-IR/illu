package pe

// This package currently parses PE32+ images for x86-64.  It does not load
// bytes into memory, apply relocations, or resolve imports.

IMAGE_DOS_SIGNATURE              :: u16(0x5A4D) // MZ
IMAGE_NT_SIGNATURE               :: u32(0x00004550) // PE\0\0
IMAGE_FILE_MACHINE_AMD64         :: u16(0x8664)
IMAGE_NT_OPTIONAL_HDR64_MAGIC    :: u16(0x20B)

DOS_HEADER_SIZE      :: 64
DOS_PE_OFFSET        :: u64(0x3C)
COFF_HEADER_SIZE     :: u64(20)
SECTION_HEADER_SIZE  :: u64(40)
MAX_SECTIONS         :: 96
PAGE_SIZE            :: u64(0x1000)

SectionCharacteristic :: enum u32 {
	Code             = 0x00000020,
	InitializedData  = 0x00000040,
	UninitializedData = 0x00000080,
	MemoryExecute    = 0x20000000,
	MemoryRead       = 0x40000000,
	MemoryWrite      = 0x80000000,
}

Section :: struct {
	name:            [8]u8,
	virtualSize:     u32,
	virtualAddress:  u32,
	rawSize:         u32,
	rawOffset:       u32,
	characteristics: u32,
}

Page :: struct {
	base:             u64,
	end:              u64,
	sectionIndex:     int,
	characteristics:  u32,
}

Error :: enum {
	None,
	TooSmall,
	InvalidDosSignature,
	InvalidPeSignature,
	UnsupportedMachine,
	UnsupportedOptionalHeader,
	InvalidHeader,
	InvalidSectionTable,
	InvalidSectionData,
	InvalidEntryPoint,
}

Image :: struct {
	machine:          u16,
	sectionCount:     u16,
	entryRva:         u32,
	entry:            u64,
	imageBase:        u64,
	sectionAlignment: u32,
	fileAlignment:    u32,
	sizeOfImage:      u32,
	sizeOfHeaders:    u32,
	sections:         [dynamic]Section,
	pages:            [dynamic]Page,
}

has_range :: proc "contextless" (data: []u8, offset, size: u64) -> bool {
	length := u64(len(data))
	return offset <= length && size <= length - offset
}

read_u16 :: proc "contextless" (data: []u8, offset: u64) -> u16 {
	i := int(offset)
	return u16(data[i]) | u16(data[i + 1]) << 8
}

read_u32 :: proc "contextless" (data: []u8, offset: u64) -> u32 {
	i := int(offset)
	return u32(data[i]) |
		u32(data[i + 1]) << 8 |
		u32(data[i + 2]) << 16 |
		u32(data[i + 3]) << 24
}

read_u64 :: proc "contextless" (data: []u8, offset: u64) -> u64 {
	return u64(read_u32(data, offset)) | u64(read_u32(data, offset + 4)) << 32
}

align_down :: proc "contextless" (value, alignment: u64) -> u64 {
	return value &~ (alignment - 1)
}

align_up :: proc "contextless" (value, alignment: u64) -> (u64, bool) {
	if value > max(u64) - (alignment - 1) do return 0, false
	return (value + alignment - 1) &~ (alignment - 1), true
}

parse :: proc (data: []u8) -> (image: Image, err: Error) {
	image.sections = make([dynamic]Section)
	image.pages = make([dynamic]Page)

	if !has_range(data, 0, DOS_HEADER_SIZE) do return image, .TooSmall
	if read_u16(data, 0) != IMAGE_DOS_SIGNATURE do return image, .InvalidDosSignature

	peOffset := u64(read_u32(data, DOS_PE_OFFSET))
	if !has_range(data, peOffset, 4 + COFF_HEADER_SIZE) do return image, .TooSmall
	if read_u32(data, peOffset) != IMAGE_NT_SIGNATURE do return image, .InvalidPeSignature

	coffOffset := peOffset + 4
	image.machine = read_u16(data, coffOffset)
	image.sectionCount = read_u16(data, coffOffset + 2)
	sizeOfOptionalHeader := u64(read_u16(data, coffOffset + 16))

	if image.machine != IMAGE_FILE_MACHINE_AMD64 do return image, .UnsupportedMachine
	if image.sectionCount == 0 || image.sectionCount > MAX_SECTIONS do return image, .InvalidHeader
	if sizeOfOptionalHeader < 64 do return image, .UnsupportedOptionalHeader

	optionalOffset := coffOffset + COFF_HEADER_SIZE
	if !has_range(data, optionalOffset, sizeOfOptionalHeader) do return image, .TooSmall
	if read_u16(data, optionalOffset) != IMAGE_NT_OPTIONAL_HDR64_MAGIC do return image, .UnsupportedOptionalHeader

	image.entryRva = read_u32(data, optionalOffset + 16)
	image.imageBase = read_u64(data, optionalOffset + 24)
	image.sectionAlignment = read_u32(data, optionalOffset + 32)
	image.fileAlignment = read_u32(data, optionalOffset + 36)
	image.sizeOfImage = read_u32(data, optionalOffset + 56)
	image.sizeOfHeaders = read_u32(data, optionalOffset + 60)
	if image.sectionAlignment == 0 || u64(image.sectionAlignment) % PAGE_SIZE != 0 do return image, .InvalidHeader
	if image.fileAlignment == 0 do return image, .InvalidHeader
	if image.entryRva == 0 do return image, .InvalidEntryPoint
	if image.imageBase > max(u64) - u64(image.entryRva) do return image, .InvalidEntryPoint
	image.entry = image.imageBase + u64(image.entryRva)

	sectionTableOffset := optionalOffset + sizeOfOptionalHeader
	sectionTableSize := u64(image.sectionCount) * SECTION_HEADER_SIZE
	if !has_range(data, sectionTableOffset, sectionTableSize) do return image, .InvalidSectionTable

	entryFound := false
	for i in 0 ..< int(image.sectionCount) {
		offset := sectionTableOffset + u64(i) * SECTION_HEADER_SIZE
		section: Section
		for j in 0 ..< 8 do section.name[j] = data[int(offset) + j]
		section.virtualSize = read_u32(data, offset + 8)
		section.virtualAddress = read_u32(data, offset + 12)
		section.rawSize = read_u32(data, offset + 16)
		section.rawOffset = read_u32(data, offset + 20)
		section.characteristics = read_u32(data, offset + 36)

		if section.rawSize != 0 && !has_range(data, u64(section.rawOffset), u64(section.rawSize)) {
			return image, .InvalidSectionData
		}
		append(&image.sections, section)

		mappedSize := u64(section.virtualSize)
		if u64(section.rawSize) > mappedSize do mappedSize = u64(section.rawSize)
		if mappedSize == 0 do continue
		sectionEnd := u64(section.virtualAddress) + mappedSize
		if sectionEnd < u64(section.virtualAddress) do return image, .InvalidHeader
		pageEnd, ok := align_up(sectionEnd, PAGE_SIZE)
		if !ok do return image, .InvalidHeader
		page := Page {
			base = align_down(u64(section.virtualAddress), PAGE_SIZE),
			end = pageEnd,
			sectionIndex = i,
			characteristics = section.characteristics,
		}
		append(&image.pages, page)

		if u64(image.entryRva) >= u64(section.virtualAddress) &&
			u64(image.entryRva) < sectionEnd &&
			(section.characteristics & u32(SectionCharacteristic.MemoryExecute)) != 0 {
			entryFound = true
		}
	}

	if !entryFound do return image, .InvalidEntryPoint
	return image, .None
}

page_is_executable :: proc "contextless" (page: Page) -> bool {
	return page.characteristics & u32(SectionCharacteristic.MemoryExecute) != 0
}
