package pe
import "../lmem"
import "../shared"
import "../syscalls"
import "base:intrinsics"
import "core:hash"

IMAGE_DOS_SIGNATURE :: u16(0x5A4D)
IMAGE_NT_SIGNATURE :: u32(0x00004550)
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

PeSection :: struct {
	name:            [8]u8,
	virtualSize:     u32,
	virtualAddress:  u32,
	rawSize:         u32,
	rawOffset:       u32,
	characteristics: u32,
}
PeError :: enum {
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
	InvalidImportTable,
	InvalidExportTable,
}
PeImportEntry :: struct {
	nameHash:  u64,
	ordinal:   u16,
	byOrdinal: bool,
	thunkRva:  u32,
}
PeImport :: struct {
	dll:     string,
	entries: [dynamic]PeImportEntry,
}

PeImage :: struct {
	machine:          u16,
	sectionCount:     u16,
	entryRva:         u32,
	entry:            u64,
	imageBase:        u64,
	sectionAlignment: u32,
	fileAlignment:    u32,
	sizeOfImage:      u32,
	sizeOfHeaders:    u32,
	regions:          [dynamic]syscalls.MemRegion,
	imports:          [dynamic]PeImport,
	exports:          map[u64]u32,
	relocations:      [dynamic]u64,
}

DATA_DIRECTORY_OFFSET :: u64(112)
DATA_DIRECTORY_ENTRY_SIZE :: u64(8)
NUMBER_OF_RVA_AND_SIZES_OFFSET :: u64(108)
RelocType :: enum u16 {
	Absolute = 0,
	Dir64    = 10,
}

DataDirectoryIndex :: enum u64 {
	Export    = 0,
	Import    = 1,
	BaseReloc = 5,
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

pe_name_hash :: proc(s: string) -> u64 {
	return hash.fnv64a(transmute([]u8)s)
}

parse_pe :: proc(
	data: []u8,
) -> (
	image: PeImage,
	sections: [dynamic; MAX_SECTIONS]PeSection,
	err: PeError,
) {
	defer if err != .None do delete(image.relocations)
	defer if err != .None do delete(image.regions)

	if !has_range(data, 0, DOS_HEADER_SIZE) do return image, sections, .TooSmall
	if read_u16(data, 0) != IMAGE_DOS_SIGNATURE do return image, sections, .InvalidDosSignature

	peOffset := u64(read_u32(data, DOS_PE_OFFSET))
	if !has_range(data, peOffset, 4 + COFF_HEADER_SIZE) do return image, sections, .TooSmall
	if read_u32(data, peOffset) != IMAGE_NT_SIGNATURE do return image, sections, .InvalidPeSignature

	coffOffset := peOffset + 4
	image.machine = read_u16(data, coffOffset)
	image.sectionCount = read_u16(data, coffOffset + 2)
	sizeOfOptionalHeader := u64(read_u16(data, coffOffset + 16))

	if image.machine != IMAGE_FILE_MACHINE_AMD64 do return image, sections, .UnsupportedMachine
	if image.sectionCount == 0 || image.sectionCount > MAX_SECTIONS do return image, sections, .InvalidHeader
	if sizeOfOptionalHeader < 64 do return image, sections, .UnsupportedOptionalHeader

	image.regions = make([dynamic]syscalls.MemRegion, 0, int(image.sectionCount))

	optionalOffset := coffOffset + COFF_HEADER_SIZE
	if !has_range(data, optionalOffset, sizeOfOptionalHeader) do return image, sections, .TooSmall
	if read_u16(data, optionalOffset) != IMAGE_NT_OPTIONAL_HDR64_MAGIC do return image, sections, .UnsupportedOptionalHeader

	image.entryRva = read_u32(data, optionalOffset + 16)
	image.imageBase = read_u64(data, optionalOffset + 24)
	image.sectionAlignment = read_u32(data, optionalOffset + 32)
	image.fileAlignment = read_u32(data, optionalOffset + 36)
	image.sizeOfImage = read_u32(data, optionalOffset + 56)
	image.sizeOfHeaders = read_u32(data, optionalOffset + 60)
	if image.sectionAlignment == 0 || u64(image.sectionAlignment) % shared.PAGE_SIZE != 0 do return image, sections, .InvalidHeader
	if image.fileAlignment == 0 do return image, sections, .InvalidHeader
	if image.entryRva != 0 {
		if image.imageBase > max(u64) - u64(image.entryRva) do return image, sections, .InvalidEntryPoint
		image.entry = image.imageBase + u64(image.entryRva)
	}


	baseRelocRva, baseRelocSize := find_data_directory(
		data,
		optionalOffset,
		sizeOfOptionalHeader,
		.BaseReloc,
	)

	sectionTableOffset := optionalOffset + sizeOfOptionalHeader
	sectionTableSize := u64(image.sectionCount) * SECTION_HEADER_SIZE
	if !has_range(data, sectionTableOffset, sectionTableSize) do return image, sections, .InvalidSectionTable

	entryFound := false
	for i in 0 ..< int(image.sectionCount) {
		offset := sectionTableOffset + u64(i) * SECTION_HEADER_SIZE
		section: PeSection
		for j in 0 ..< 8 do section.name[j] = data[int(offset) + j]
		section.virtualSize = read_u32(data, offset + 8)
		section.virtualAddress = read_u32(data, offset + 12)
		section.rawSize = read_u32(data, offset + 16)
		section.rawOffset = read_u32(data, offset + 20)
		section.characteristics = read_u32(data, offset + 36)

		if section.rawSize != 0 && !has_range(data, u64(section.rawOffset), u64(section.rawSize)) {
			return image, sections, .InvalidSectionData
		}
		append(&sections, section)

		mappedSize := u64(section.virtualSize)
		if u64(section.rawSize) > mappedSize do mappedSize = u64(section.rawSize)
		if mappedSize == 0 do continue
		sectionEnd := u64(section.virtualAddress) + mappedSize
		if sectionEnd < u64(section.virtualAddress) do return image, sections, .InvalidHeader
		pageEnd, ok := align_up(sectionEnd, shared.PAGE_SIZE)
		if !ok do return image, sections, .InvalidHeader
		if pageEnd > u64(image.sizeOfImage) do return image, sections, .InvalidHeader

		base := align_down(u64(section.virtualAddress), shared.PAGE_SIZE)
		size := pageEnd - base

		append(
			&image.regions,
			syscalls.MemRegion {
				phys = 0,
				logical = image.imageBase + base,
				size = size,
				pageSize = ._4KB,
				flags = region_flags_for(section.characteristics),
			},
		)
		if u64(image.entryRva) >= u64(section.virtualAddress) &&
		   u64(image.entryRva) < sectionEnd &&
		   (section.characteristics & u32(SectionCharacteristic.MemoryExecute)) != 0 {
			entryFound = true
		}
	}

	if baseRelocSize > 0 {
		image.relocations = make([dynamic]u64, 0, int(baseRelocSize / 2))
		relocFileOffset, relocOk := rva_to_file_offset(sections[:], baseRelocRva)
		if !relocOk || !has_range(data, relocFileOffset, u64(baseRelocSize)) do return image, sections, .InvalidRelocationTable
		blockOffset := relocFileOffset
		relocEnd := relocFileOffset + u64(baseRelocSize)

		for blockOffset + 8 <= relocEnd {
			pageRva := read_u32(data, blockOffset)
			blockSize := u64(read_u32(data, blockOffset + 4))

			if blockSize < 8 || blockOffset + blockSize > relocEnd do return image, sections, .InvalidRelocationTable

			entryCount := (blockSize - 8) / 2

			for i in u64(0) ..< entryCount {
				entry := read_u16(data, blockOffset + 8 + i * 2)
				relocType := RelocType(entry >> 12)
				relocOffsetInPage := u64(entry & 0x0FFF)
				if relocType == .Dir64 {
					relocRva := u64(pageRva) + relocOffsetInPage
					if relocRva + 8 > u64(image.sizeOfImage) do return image, sections, .InvalidRelocationTable
					append(&image.relocations, relocRva)
				}

			}
			blockOffset += blockSize

		}
	}


	if image.entryRva != 0 && !entryFound do return image, sections, .InvalidEntryPoint

	defer if err != .None {
		for imp in image.imports do delete(imp.entries)
		delete(image.imports)
	}

	importRva, importSize := find_data_directory(
		data,
		optionalOffset,
		sizeOfOptionalHeader,
		.Import,
	)

	if importSize > 0 {
		image.imports = make([dynamic]PeImport)
		descOffset, descOk := rva_to_file_offset(sections[:], importRva)
		if !descOk do return image, sections, .InvalidImportTable

		for {
			if !has_range(data, descOffset, 20) do return image, sections, .InvalidImportTable
			nameRva := read_u32(data, descOffset + 12)
			firstThunkRva := read_u32(data, descOffset + 16)
			if nameRva == 0 && firstThunkRva == 0 do break

			nameOffset, nameOk := rva_to_file_offset(sections[:], nameRva)
			if !nameOk do return image, sections, .InvalidImportTable
			dllName, dllOk := read_cstr(data, nameOffset)
			if !dllOk do return image, sections, .InvalidImportTable

			imp: PeImport
			imp.dll = dllName
			thunkFileOffset, thunkOk := rva_to_file_offset(sections[:], firstThunkRva)
			if !thunkOk do return image, sections, .InvalidImportTable

			thunkRva := firstThunkRva
			for {
				if !has_range(data, thunkFileOffset, 8) do return image, sections, .InvalidImportTable
				thunkVal := read_u64(data, thunkFileOffset)
				if thunkVal == 0 do break
				if u64(thunkRva) + 8 > u64(image.sizeOfImage) do return image, sections, .InvalidImportTable

				if thunkVal & 0x8000000000000000 != 0 {
					append(
						&imp.entries,
						PeImportEntry {
							ordinal = u16(thunkVal & 0xFFFF),
							byOrdinal = true,
							thunkRva = thunkRva,
						},
					)
				} else {
					hintNameOffset, hnOk := rva_to_file_offset(sections[:], u32(thunkVal))
					if !hnOk do return image, sections, .InvalidImportTable
					fnName, fnOk := read_cstr(data, hintNameOffset + 2)
					if !fnOk do return image, sections, .InvalidImportTable
					append(
						&imp.entries,
						PeImportEntry{nameHash = pe_name_hash(fnName), thunkRva = thunkRva},
					)
				}
				thunkFileOffset += 8
				thunkRva += 8
			}
			append(&image.imports, imp)
			descOffset += 20
		}
	}


	exportRva, exportSize := find_data_directory(
		data,
		optionalOffset,
		sizeOfOptionalHeader,
		.Export,
	)
	defer if err != {} do delete(image.exports)

	if exportSize > 0 {
		dirOffset, dirOk := rva_to_file_offset(sections[:], exportRva)
		if !dirOk || !has_range(data, dirOffset, 40) do return image, sections, .InvalidExportTable

		numberOfNames := read_u32(data, dirOffset + 24)
		addressOfFunctionsRva := read_u32(data, dirOffset + 28)
		addressOfNamesRva := read_u32(data, dirOffset + 32)
		addressOfNameOrdinalsRva := read_u32(data, dirOffset + 36)

		namesTableOff, namesTableOk := rva_to_file_offset(sections[:], addressOfNamesRva)
		if !namesTableOk || !has_range(data, namesTableOff, u64(numberOfNames) * 4) do return image, sections, .InvalidExportTable

		ordsTableOff, ordsTableOk := rva_to_file_offset(sections[:], addressOfNameOrdinalsRva)
		if !ordsTableOk || !has_range(data, ordsTableOff, u64(numberOfNames) * 2) do return image, sections, .InvalidExportTable

		image.exports = make(map[u64]u32, numberOfNames)

		for i in u32(0) ..< numberOfNames {
			nameRvaAddr, nameRvaAddrOverflow := intrinsics.overflow_add(addressOfNamesRva, i * 4)
			if nameRvaAddrOverflow do return image, sections, .InvalidExportTable
			nameRvaOff, ok1 := rva_to_file_offset(sections[:], nameRvaAddr)
			if !ok1 || !has_range(data, nameRvaOff, 4) do return image, sections, .InvalidExportTable
			nameRva := read_u32(data, nameRvaOff)

			ordAddr, ordAddrOverflow := intrinsics.overflow_add(addressOfNameOrdinalsRva, i * 2)
			if ordAddrOverflow do return image, sections, .InvalidExportTable
			ordOff, ok2 := rva_to_file_offset(sections[:], ordAddr)
			if !ok2 || !has_range(data, ordOff, 2) do return image, sections, .InvalidExportTable
			ordinal := read_u16(data, ordOff)

			funcAddr, funcAddrOverflow := intrinsics.overflow_add(
				addressOfFunctionsRva,
				u32(ordinal) * 4,
			)
			if funcAddrOverflow do return image, sections, .InvalidExportTable
			funcOff, ok3 := rva_to_file_offset(sections[:], funcAddr)
			if !ok3 || !has_range(data, funcOff, 4) do return image, sections, .InvalidExportTable
			funcRva := read_u32(data, funcOff)

			nameOff, ok4 := rva_to_file_offset(sections[:], nameRva)
			if !ok4 do return image, sections, .InvalidExportTable
			name, nameOk := read_cstr(data, nameOff)
			if !nameOk do return image, sections, .InvalidExportTable

			image.exports[pe_name_hash(name)] = funcRva
		}
	}
	return image, sections, .None
}

region_flags_for :: proc(characteristics: u32) -> (flags: lmem.PageFlags) {
	flags += {.User}
	if characteristics & u32(SectionCharacteristic.MemoryWrite) != 0 do flags += {.Write}
	if characteristics & u32(SectionCharacteristic.MemoryExecute) == 0 do flags += {.NX}
	return flags
}

rva_to_file_offset :: proc "contextless" (
	sections: []PeSection,
	rva: u32,
) -> (
	offset: u64,
	ok: bool,
) {
	for section in sections {
		start := section.virtualAddress
		size := section.virtualSize
		if size == 0 do size = section.rawSize
		if rva >= start && u64(rva) < u64(start) + u64(size) {
			return u64(section.rawOffset) + u64(rva - start), true
		}
	}
	return 0, false
}
