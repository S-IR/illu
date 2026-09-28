package uefi
import "../lib/elf"
import "../lib/shared"
import "core:mem"
load_elf :: proc "contextless" (
	root: ^EFI_FILE_PROTOCOL,
	name: [^]u16,
	systemTable: ^EFI_SYSTEM_TABLE,
	atLinkAddress: bool,
) -> (
	image: elf.ElfImage,
	ok: bool,
) {
	f: ^EFI_FILE_PROTOCOL
	if root.Open(root, &f, name, EFI_FILE_MODE_READ, 0) != .SUCCESS do return {}, false
	defer f.Close(f)

	header: elf.ElfHdr
	headerSize: u64 = size_of(elf.ElfHdr)
	if f.SetPosition(f, 0) != .SUCCESS do return {}, false
	if f.Read(f, &headerSize, rawptr(&header)) != .SUCCESS do return {}, false
	if headerSize != size_of(header) do return {}, false
	if !elf.is_valid_elf(header.eIdent) || !elf.is_64bit(header.eIdent) do return {}, false
	if header.machine != .X86_64 do return {}, false
	if header.phentsize != size_of(elf.ElfPhdr) do return {}, false
	if header.phnum == 0 || header.phnum > elf.MAX_SEGMENTS do return {}, false

	phdrs: [elf.MAX_SEGMENTS]elf.ElfPhdr

	if f.SetPosition(f, header.phoff) != .SUCCESS do return {}, false
	want := u64(header.phnum) * u64(size_of(elf.ElfPhdr))

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
		if end < ph.vaddr do return {}, false
		if end > maxVaddr do maxVaddr = end
	}
	if maxVaddr == 0 do return {}, false

	allocBase := minVaddr &~ (shared.PAGE_SIZE - 1)
	pages := (maxVaddr - allocBase + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE
	efiAddr := EFI_PHYSICAL_ADDRESS(allocBase)
	allocType := EFI_ALLOCATE_TYPE.AllocateAddress if atLinkAddress else .AllocateAnyPages
	if systemTable.BootServices.AllocatePages(allocType, .LoaderData, pages, &efiAddr) != .SUCCESS do return {}, false
	physBase := u64(efiAddr) - allocBase
	uefiAssert(systemTable, !atLinkAddress || physBase == 0)

	for ph in foundPhdrs {
		if ph.type != .Load do continue

		dest := ph.vaddr + physBase
		if f.SetPosition(f, ph.offset) != .SUCCESS do return {}, false
		read: u64 = ph.filesz
		if f.Read(f, &read, rawptr(uintptr(dest))) != .SUCCESS || read != ph.filesz do return {}, false
		mem.zero(rawptr(uintptr(dest + ph.filesz)), int(ph.memsz - ph.filesz))
		segment: elf.ElfSegment = {
			perms = ph.flags,
			base  = dest,
			end   = dest + ph.memsz,
		}
		append(&image.segments, segment)
	}
	if dynAddrVaddr != 0 {
		uefiAssert(systemTable, dynSize != 0)
		numDyns := dynSize / size_of(elf.DynamicEntry)
		dyns := mem.slice_ptr((^elf.DynamicEntry)(uintptr(physBase + dynAddrVaddr)), int(numDyns))

		relaVaddr, relaSz, relaEnt: u64
		outer: for entry in dyns {
			#partial switch entry.dTag {
			case .RELA:
				relaVaddr = entry.dVal
			case .RELASZ:
				relaSz = entry.dVal
			case .RELAENT:
				relaEnt = entry.dVal
			case .NULL:
				break outer
			}
		}
		if relaSz != 0 {
			if relaEnt != size_of(elf.RelaEntry) do return {}, false
			if relaVaddr < allocBase || relaVaddr + relaSz > maxVaddr do return {}, false
			relas := mem.slice_ptr((^elf.RelaEntry)(uintptr(physBase + relaVaddr)), int(relaSz / relaEnt))
			for rela in relas {
				if elf.rela_type(rela.rInfo) != .RELATIVE do return {}, false
				if rela.rOffset < allocBase || rela.rOffset + size_of(u64) > maxVaddr do return {}, false
				(^u64)(uintptr(physBase + rela.rOffset))^ = physBase + u64(rela.rAddend)
			}
		}
	}

	image.entry = header.entry + physBase
	image.base = allocBase + physBase
	image.end = maxVaddr + physBase
	return image, true
}

uefiAssert :: proc "contextless" (
	st: ^EFI_SYSTEM_TABLE,
	condition: bool,
	message := #caller_expression(condition),
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
// Symbols the Odin runtime and lld-link expect to exist under
// -target:freestanding_amd64_win64, normally supplied by a real Windows CRT.
// Only compiled in for the bootloader's own build (UEFI_BUILD=true) -- when
// this package is pulled in by kernel (freestanding_amd64_sysv), core:runtime
// already provides these, and Odin has no way to conditionally `import`
// lib/win64rt's copy per-target, so they're duplicated here. See
// lib/win64rt/win64rt.odin for the twin copy used by win64-only packages.
when #config(UEFI_BUILD, false) {
	@(export, link_name = "_fltused")
	_fltused: i32 = 1

	@(export, link_name = "_tls_index")
	_tls_index: u32 = 0

	@(export, link_name = "memcpy")
	mcpy :: proc "c" (dst, src: rawptr, #any_int len: uint) -> rawptr {
		d := ([^]u8)(dst)
		s := ([^]u8)(src)
		for i in 0 ..< len do d[i] = s[i]
		return dst
	}

	@(export, link_name = "memset")
	mset :: proc "c" (ptr: rawptr, val: i32, #any_int len: uint) -> rawptr {
		d := ([^]u8)(ptr)
		for i in 0 ..< len do d[i] = u8(val)
		return ptr
	}

	@(export, link_name = "memmove")
	mmove :: proc "c" (dst, src: rawptr, #any_int len: uint) -> rawptr {
		d := ([^]u8)(dst)
		s := ([^]u8)(src)
		if uintptr(dst) < uintptr(src) {
			for i in 0 ..< len do d[i] = s[i]
		} else {
			for i := len; i > 0; i -= 1 do d[i - 1] = s[i - 1]
		}
		return dst
	}
}
