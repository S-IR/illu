package pe
import "../lmem"
import "../shared"
import "../syscalls"
// This package currently parses PE32+ images for x86-64.  It does not load
// bytes into memory, apply relocations, or resolve imports.

IMAGE_DOS_SIGNATURE :: u16(0x5A4D) // MZ
IMAGE_NT_SIGNATURE :: u32(0x00004550) // PE\0\0
IMAGE_FILE_MACHINE_AMD64 :: u16(0x8664)
IMAGE_NT_OPTIONAL_HDR64_MAGIC :: u16(0x20B)

DOS_HEADER_SIZE :: 64
DOS_PE_OFFSET :: u64(0x3C)
COFF_HEADER_SIZE :: u64(20)
SECTION_HEADER_SIZE :: u64(40)
MAX_SECTIONS :: 96

SectionCharacteristic :: enum u32 {
	Code              = 0x00000020,
	InitializedData   = 0x00000040,
	UninitializedData = 0x00000080,
	MemoryExecute     = 0x20000000,
	MemoryRead        = 0x40000000,
	MemoryWrite       = 0x80000000,
}

Section :: struct {
	name:            [8]u8,
	virtualSize:     u32,
	virtualAddress:  u32,
	rawSize:         u32,
	rawOffset:       u32,
	characteristics: u32,
}
Region :: struct {
	regionData:   syscalls.MemRegion,
	sectionIndex: int,
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
	InvalidRelocationTable,
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
	regions:          [dynamic]Region,
	relocations:      [dynamic]u64,
}

DATA_DIRECTORY_OFFSET :: u64(112)
DATA_DIRECTORY_ENTRY_SIZE :: u64(8)
IMAGE_DIRECTORY_ENTRY_BASERELOC :: u64(5)
IMAGE_REL_BASED_ABSOLUTE :: u16(0)
IMAGE_REL_BASED_DIR64 :: u16(10)


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
	return u32(data[i]) | u32(data[i + 1]) << 8 | u32(data[i + 2]) << 16 | u32(data[i + 3]) << 24
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
//x64 ONLY
parse :: proc(data: []u8) -> (image: Image, err: Error) {
	image.sections = make([dynamic]Section)
	defer if err != .None do delete(image.sections)

	image.relocations = make([dynamic]u64)
	defer if err != .None do delete(image.relocations)

	image.regions = make([dynamic]Region)
	defer if err != .None do delete(image.regions)


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
	if image.sectionAlignment == 0 || u64(image.sectionAlignment) % shared.PAGE_SIZE != 0 do return image, .InvalidHeader
	if image.fileAlignment == 0 do return image, .InvalidHeader
	if image.entryRva == 0 do return image, .InvalidEntryPoint
	if image.imageBase > max(u64) - u64(image.entryRva) do return image, .InvalidEntryPoint
	image.entry = image.imageBase + u64(image.entryRva)

	baseRelocRva: u32
	baseRelocSize: u32

	findBaseReloc: {
		if sizeOfOptionalHeader < DATA_DIRECTORY_OFFSET do break findBaseReloc

		RVA_RELOC_OFFSET :: 108
		numberOfRvaAndSizesOffset := optionalOffset + RVA_RELOC_OFFSET
		if !has_range(data, numberOfRvaAndSizesOffset, 4) do return image, .TooSmall
		numberOfRvasAndSizes := u64(read_u32(data, numberOfRvaAndSizesOffset))
		if numberOfRvasAndSizes <= IMAGE_DIRECTORY_ENTRY_BASERELOC do break findBaseReloc

		dirOffset :=
			optionalOffset +
			DATA_DIRECTORY_OFFSET +
			IMAGE_DIRECTORY_ENTRY_BASERELOC * DATA_DIRECTORY_ENTRY_SIZE
		if dirOffset + DATA_DIRECTORY_ENTRY_SIZE > optionalOffset + sizeOfOptionalHeader do return image, .InvalidHeader
		if !has_range(data, dirOffset, DATA_DIRECTORY_ENTRY_SIZE) do return image, .TooSmall

		baseRelocRva = read_u32(data, dirOffset)
		baseRelocSize = read_u32(data, dirOffset + 4)

	}
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
		pageEnd, ok := align_up(sectionEnd, shared.PAGE_SIZE)
		if !ok do return image, .InvalidHeader
		if pageEnd > u64(image.sizeOfImage) do return image, .InvalidHeader

		base := align_down(u64(section.virtualAddress), shared.PAGE_SIZE)
		size := pageEnd - base

		append(
			&image.regions,
			Region {
				regionData = {
					phys = 0,
					logical = image.imageBase + base,
					size = size,
					pageSize = ._4KB,
					flags = region_flags_for(section.characteristics),
				},
				sectionIndex = i,
			},
		)
		if u64(image.entryRva) >= u64(section.virtualAddress) &&
		   u64(image.entryRva) < sectionEnd &&
		   (section.characteristics & u32(SectionCharacteristic.MemoryExecute)) != 0 {
			entryFound = true
		}
	}

	if baseRelocSize > 0 {
		relocFileOffset, relocOk := rva_to_file_offset(&image, baseRelocRva)
		if !relocOk || !has_range(data, relocFileOffset, u64(baseRelocSize)) do return image, .InvalidRelocationTable
		blockOffset := relocFileOffset
		relocEnd := relocFileOffset + u64(baseRelocSize)

		for blockOffset + 8 <= relocEnd {
			pageRva := read_u32(data, blockOffset)
			blockSize := u64(read_u32(data, blockOffset + 4))

			if blockSize < 8 || blockOffset + blockSize > relocEnd do return image, .InvalidRelocationTable

			entryCount := (blockSize - 8) / 2

			for i in u64(0) ..< entryCount {
				entry := read_u16(data, blockOffset + 8 + i * 2)
				relocType := entry >> 12
				relocOffsetInPage := u64(entry & 0x0FFF)
				if relocType == IMAGE_REL_BASED_DIR64 {
					append(&image.relocations, u64(pageRva) + relocOffsetInPage)
					// IMAGE_REL_BASED_ABSOLUTE (0, padding) and any other type
					// (e.g. HIGHLOW, x86-only) are silently skipped -- this
					// loader targets x64 only.
				}

			}
			blockOffset += blockSize

		}
	}
	if !entryFound do return image, .InvalidEntryPoint
	return image, .None
}

image_destroy :: proc(image: ^Image) {
	delete(image.sections)
	delete(image.regions)
	delete(image.relocations)

}
region_flags_for :: proc(characteristics: u32) -> (flags: lmem.PageFlags) {
	flags += {.User}
	if characteristics & u32(SectionCharacteristic.MemoryWrite) != 0 do flags += {.Write}
	if characteristics & u32(SectionCharacteristic.MemoryExecute) == 0 do flags += {.NX}
	return flags
}

rva_to_file_offset :: proc "contextless" (image: ^Image, rva: u32) -> (offset: u64, ok: bool) {
	for section in image.sections {
		start := section.virtualAddress
		size := section.virtualSize
		if size == 0 do size = section.rawSize
		if rva >= start && u64(rva) < u64(start) + u64(size) {
			return u64(section.rawOffset) + u64(rva - start), true
		}
	}
	return 0, false
}
