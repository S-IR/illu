package uefi
import "../lib/elf"
import "../lib/shared"
import "core:mem"
load_elf :: proc "contextless" (
	root: ^EFI_FILE_PROTOCOL,
	name: [^]u16,
	bs: ^EFI_BOOT_SERVICES,
	systemTable: ^EFI_SYSTEM_TABLE,
	//-1 means pie
	desiredPhysicalAddr: int = -1,
) -> (
	image: elf.Image,
	ok: bool,
) {
	f: ^EFI_FILE_PROTOCOL
	if root.Open(root, &f, name, EFI_FILE_MODE_READ, 0) != .SUCCESS do return {}, false
	defer f.Close(f)

	header: elf.Hdr
	headerSize: u64 = size_of(elf.Hdr)
	if f.SetPosition(f, 0) != .SUCCESS do return {}, false
	if f.Read(f, &headerSize, rawptr(&header)) != .SUCCESS do return {}, false
	magic :=
		u64(header.eIdent[0]) |
		u64(header.eIdent[1]) << 8 |
		u64(header.eIdent[2]) << 16 |
		u64(header.eIdent[3]) << 24

	if headerSize != size_of(header) do return
	if !elf.is_valid_elf(header.eIdent) || !elf.is_64bit(header.eIdent) do return {}, false
	if header.machine != .X86_64 do return {}, false
	if header.phnum == 0 || header.phnum > elf.MAX_SEGMENTS do return {}, false

	phdrs: [elf.MAX_SEGMENTS]elf.Phdr

	if f.SetPosition(f, header.phoff) != .SUCCESS do return {}, false
	want := u64(header.phnum) * u64(size_of(elf.Phdr))

	actualSize := want
	if f.Read(f, &actualSize, raw_data(phdrs[:])) != .SUCCESS do return {}, false
	if actualSize != want do return {}, false

	minVaddr := ~u64(0)
	maxVaddr: u64 = 0

	foundPhdrs := phdrs[:int(header.phnum)]
	dynAddrVaddr, dynSize: u64
	for ph in foundPhdrs {
		if ph.type == .Dynamic {
			uefiAssert(systemTable, dynAddrVaddr == 0)
			uefiAssert(systemTable, dynSize == 0)
			dynAddrVaddr = ph.vaddr
			dynSize = ph.filesz
		}
		if ph.type != .Load do continue
		if ph.filesz > ph.memsz do return {}, false
		if ph.vaddr < minVaddr do minVaddr = ph.vaddr
		end := ph.vaddr + ph.memsz
		if end > maxVaddr do maxVaddr = end

	}
	if maxVaddr == 0 do return {}, false

	allocBase := minVaddr &~ (shared.PAGE_SIZE - 1)
	pages := (maxVaddr - allocBase + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE

	physBase: u64 = 42
	if desiredPhysicalAddr == -1 {
		efiAddr: EFI_PHYSICAL_ADDRESS
		if bs.AllocatePages(.AllocateAnyPages, .LoaderData, pages, &efiAddr) != .SUCCESS do return {}, false
		physBase = u64(efiAddr) - allocBase
	} else {
		efiAddr := EFI_PHYSICAL_ADDRESS(desiredPhysicalAddr)
		if bs.AllocatePages(.AllocateAddress, .LoaderData, pages, &efiAddr) != .SUCCESS do return {}, false
		physBase = u64(efiAddr) - allocBase
	}
	for ph in foundPhdrs {
		if ph.type != .Load do continue

		dest := ph.vaddr + physBase
		mem := ([^]u8)(uintptr(dest))

		for j in u64(0) ..< ph.memsz do mem[j] = 0

		if f.SetPosition(f, ph.offset) != .SUCCESS do return {}, false
		read: u64 = ph.filesz
		if f.Read(f, &read, rawptr(uintptr(dest))) != .SUCCESS || read != ph.filesz do return {}, false
		segment: elf.Segment = {
			perms = ph.flags,
			base  = dest,
			end   = dest + ph.memsz,
		}
		append(&image.segments, segment)
	}
	if dynAddrVaddr != 0 {
		dynSegmentPhysAddr := physBase + dynAddrVaddr
		uefiAssert(systemTable, dynSize != 0)
		numDyns := dynSize / size_of(elf.DynamicEntry)
		dyns := mem.slice_ptr((^elf.DynamicEntry)(uintptr(dynSegmentPhysAddr)), int(numDyns))

		relaAddr, relaSz, relaEnt: u64
		outer: for entry in dyns {
			#partial switch entry.dTag {
			case .RELA:
				relaAddr = physBase + entry.dVal
			case .RELASZ:
				relaSz = entry.dVal
			case .RELAENT:
				relaEnt = entry.dVal
			case .NULL:
				break outer
			case:
				continue outer
			}
		}
		if relaAddr != 0 && relaSz != 0 && relaEnt == size_of(elf.RelaEntry) {
			numRelas := relaSz / relaEnt

			relas := mem.slice_ptr((^elf.RelaEntry)(uintptr(relaAddr)), int(numRelas))
			for &rela in relas {
				if elf.rela_type(rela.rInfo) != .RELATIVE do continue
				target := (^u64)(uintptr(physBase + rela.rOffset))
				target^ = physBase + u64(rela.rAddend)
			}
		}
	}


	raw := cast(^[64]u8)&header

	image.entry = header.entry + physBase
	image.base = allocBase + physBase
	image.end = maxVaddr + physBase
	return image, true
}
print_hex :: proc "contextless" (st: ^EFI_SYSTEM_TABLE, val: u64) {
	buf: [20]u16
	buf[0] = '0'
	buf[1] = 'x'
	v := val
	i := 17
	buf[18] = '\r'
	buf[19] = 0
	for i >= 2 {
		nibble := v & 0xF
		buf[i] = u16('0' + nibble) if nibble < 10 else u16('A' + nibble - 10)
		v >>= 4
		i -= 1
	}
	st.ConOut.OutputString(st.ConOut, &buf[0])
}


uefiAssert :: proc "contextless" (
	st: ^EFI_SYSTEM_TABLE,
	condition: bool,
	message := #caller_expression(condition),
	loc := #caller_location,
) {
	if !condition {
		print_uefi_string(st, message)
		for {} 	// hang
	}
}
// Print an Odin string (ASCII only) to the UEFI console.
// Must be called *before* ExitBootServices.
// The string must be ≤ 127 characters — enough for assert messages.
print_uefi_string :: proc "contextless" (st: ^EFI_SYSTEM_TABLE, s: string) {
	if st.ConOut == nil || st.ConOut.OutputString == nil do return

	// Stack buffer for the wide string (max 128 chars + null)
	buf: [128]u16
	for c, i in s {
		if i >= 127 do break
		buf[i] = u16(c)
	}
	buf[min(len(s), 127)] = 0 // null terminator
	st.ConOut.OutputString(st.ConOut, &buf[0])
}
print_hex_line :: proc "contextless" (st: ^EFI_SYSTEM_TABLE, val: u64) {
	print_hex(st, val)
	newline := [?]u16{'\r', '\n', 0}
	st.ConOut.OutputString(st.ConOut, &newline[0])
}
