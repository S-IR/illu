// UEFI resources
//
// Official spec (THE reference — all structs, protocols, calling conventions):
//   https://uefi.org/specs/UEFI/2.10/
//   Download PDF: https://uefi.org/specifications
//
// OSDev UEFI overview (concepts, memory map, ExitBootServices flow):
//   https://wiki.osdev.org/UEFI
//
// OSDev UEFI App Bare Bones (minimal app, build setup, calling conventions):
//   https://wiki.osdev.org/UEFI_App_Bare_Bones
//
// TianoCore EDK2 header files (authoritative C struct definitions for every protocol):
//   https://github.com/tianocore/edk2/tree/master/MdePkg/Include/Uefi
//   Specific file for core types: MdePkg/Include/Uefi/UefiSpec.h
//
// pbatard/uefi-simple (minimal UEFI app, no EDK2 dependency, easy to read):
//   https://github.com/pbatard/uefi-simple
//
// Limine bootloader (production-quality UEFI bootloader in C — great to diff against):
//   https://github.com/limine-bootloader/limine
//
// uefi-rs (Rust UEFI bindings — clean typed wrappers, good mental model for each protocol):
//   https://github.com/rust-osdev/uefi-rs
//   Docs: https://docs.rs/uefi/latest/uefi/
//
// BOOTBOOT (another minimal UEFI bootloader, Odin-friendly flat binary model):
//   https://gitlab.com/bztsrc/bootboot
//
// ExitBootServices gotchas (why you must re-call GetMemoryMap in a loop):
//   https://wiki.osdev.org/EFI#Getting_the_Memory_Map
//
// GOP (Graphics Output Protocol) — framebuffer setup:
//   UEFI 2.10 §12.9 — EFI_GRAPHICS_OUTPUT_PROTOCOL
//   OSDev: https://wiki.osdev.org/GOP
//
// EFI memory map descriptor types (what's usable RAM vs firmware reserved):
//   https://wiki.osdev.org/UEFI#Memory_Map
//
// FreeBSD UEFI boot loader (production C — GOP, memory map, file loading, all in one place):
//   https://github.com/freebsd/freebsd-src/tree/main/stand/efi/loader
//
// FreeBSD EFI include headers (clean C struct definitions mirrors of the spec):
//   https://github.com/freebsd/freebsd-src/tree/main/stand/efi/include
//
// FreeBSD EFI libefi (shared helpers — ExitBootServices, memory map, console):
//   https://github.com/freebsd/freebsd-src/tree/main/stand/efi/libefi

package efi
import "../lib/elf"
import "../lib/shared"
import "core:slice"
KernelParams :: struct #all_or_none {
	fb:                shared.FrameBuffer,
	rsdp:              rawptr,
	memoryMap:         [^]EFI_MEMORY_DESCRIPTOR,
	memoryMapSize:     u64,
	memoryMapDescSize: u64,
	kernelImg:         elf.Image,
}


guid_equal :: proc "contextless" (a, b: ^EFI_GUID) -> bool {
	if a.Data1 != b.Data1 || a.Data2 != b.Data2 || a.Data3 != b.Data3 do return false
	for i in 0 ..< 8 {
		if a.Data4[i] != b.Data4[i] do return false
	}
	return true
}

// Print an error to the firmware console and hang. Only usable before
// ExitBootServices (ConOut is a boot service).
@(private)
boot_fail :: proc "contextless" (st: ^EFI_SYSTEM_TABLE, msg: ^u16) {
	if st.ConOut != nil && st.ConOut.OutputString != nil {
		st.ConOut.OutputString(st.ConOut, msg)
	}
	for {}
}

@(export)
efi_main :: proc "win64" (imageHandle: EFI_HANDLE, systemTable: ^EFI_SYSTEM_TABLE) -> EFI_STATUS {

	// UEFI 2.10 §7.3.16 LocateProtocol https://uefi.org/specifications
	gop: ^EFI_GRAPHICS_OUTPUT_PROTOCOL
	if systemTable.BootServices.LocateProtocol(&GOP_GUID, nil, cast(^^VOID)&gop) != .SUCCESS ||
	   gop == nil ||
	   gop.Mode == nil ||
	   gop.Mode.Info == nil {
		boot_fail(systemTable, &errGop[0])
	}

	// UEFI 2.10 §7.3.5 HandleProtocol https://uefi.org/specifications
	loadedImage: ^EFI_LOADED_IMAGE_PROTOCOL
	if systemTable.BootServices.HandleProtocol(imageHandle, &LIP_GUID, cast(^^VOID)&loadedImage) !=
		   .SUCCESS ||
	   loadedImage == nil {
		boot_fail(systemTable, &errLip[0])
	}
	// before ExitBootServices, so ConOut still works
	msg := [?]u16{'J', 'U', 'M', 'P', 'I', 'N', 'G', '\r', '\n', 0}
	systemTable.ConOut.OutputString(systemTable.ConOut, &msg[0])

	// UEFI 2.10 §7.3.5 HandleProtocol https://uefi.org/specifications
	fs: ^EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
	if systemTable.BootServices.HandleProtocol(
		   loadedImage.DeviceHandle,
		   &FS_GUID,
		   cast(^^VOID)&fs,
	   ) !=
		   .SUCCESS ||
	   fs == nil {
		boot_fail(systemTable, &errFs[0])
	}

	// UEFI 2.10 §13.4.2 OpenVolume https://uefi.org/specifications
	root: ^EFI_FILE_PROTOCOL
	if fs.OpenVolume(fs, &root) != .SUCCESS || root == nil {
		boot_fail(systemTable, &errFs[0])
	}

	kernelName := [?]u16{'k', 'e', 'r', 'n', 'e', 'l', '.', 'e', 'l', 'f', 0}
	// fsDaemonName := [?]u16{'f', 's', '_', 'd', 'a', 'e', 'm', 'o', 'n', '.', 'e', 'l', 'f', 0}
	// before ExitBootServices, so ConOut still works
	msg2 := [?]u16{'J', 'U', 'M', 'P', 'I', 'N', '2', '\r', '\n', 0}
	systemTable.ConOut.OutputString(systemTable.ConOut, &msg2[0])

	kernelImg, kernelOk := load_elf(
		root,
		&kernelName[0],
		systemTable.BootServices,
		systemTable,
		shared.KERNEL_PHYSICAL_MEM_LOCATION,
	)
	if !kernelOk do boot_fail(systemTable, &errKernel[0])

	rsdp: rawptr = nil
	configTable := slice.from_ptr(
		systemTable.ConfigurationTable,
		int(systemTable.NumberOfTableEntries),
	)
	// before ExitBootServices, so ConOut still works
	msg3 := [?]u16{'J', 'U', 'M', 'P', 'I', 'N', '3', '\r', '\n', 0}
	systemTable.ConOut.OutputString(systemTable.ConOut, &msg3[0])

	for &t in configTable {
		if guid_equal(&t.VendorGuid, &ACPI2_GUID) {
			rsdp = rawptr(t.VendorTable)
			break
		}
		if guid_equal(&t.VendorGuid, &ACPI1_GUID) && rsdp == nil {
			rsdp = rawptr(t.VendorTable)
		}
	}
	if rsdp == nil do boot_fail(systemTable, &errRsdp[0])

	mmapSize, mapKey, descSize: u64 = 0, 0, 0
	descVer: u32 = 0
	systemTable.BootServices.GetMemoryMap(&mmapSize, nil, &mapKey, &descSize, &descVer)
	mmapSize += descSize

	mmapStartPtr: rawptr
	if systemTable.BootServices.AllocatePool(.LoaderData, mmapSize, &mmapStartPtr) != .SUCCESS ||
	   mmapStartPtr == nil {
		boot_fail(systemTable, &errMmap[0])
	}

	if systemTable.BootServices.GetMemoryMap(
		   &mmapSize,
		   cast(^EFI_MEMORY_DESCRIPTOR)mmapStartPtr,
		   &mapKey,
		   &descSize,
		   &descVer,
	   ) !=
	   .SUCCESS {
		boot_fail(systemTable, &errMmap[0])
	}

	for systemTable.BootServices.ExitBootServices(imageHandle, mapKey) != .SUCCESS {
		mmapSize += descSize
		if systemTable.BootServices.GetMemoryMap(
			   &mmapSize,
			   cast(^EFI_MEMORY_DESCRIPTOR)mmapStartPtr,
			   &mapKey,
			   &descSize,
			   &descVer,
		   ) !=
		   .SUCCESS {
			//failure
			{}
			// boot_fail(systemTable, &errMmap[0])
		}
	}


	params := KernelParams {
		fb = {
			base = cast([^]u32)rawptr(uintptr(gop.Mode.FrameBufferBase)),
			width = u64(gop.Mode.Info.HorizontalResolution),
			height = u64(gop.Mode.Info.VerticalResolution),
			stride = u64(gop.Mode.Info.PixelsPerScanLine),
		},
		rsdp = rsdp,
		memoryMap = cast([^]EFI_MEMORY_DESCRIPTOR)mmapStartPtr,
		memoryMapSize = u64(mmapSize),
		memoryMapDescSize = u64(descSize),
		kernelImg = kernelImg,
	}
	KernelEntry :: #type proc "sysv" (params: ^KernelParams)


	kernelMain := cast(KernelEntry)rawptr(uintptr(kernelImg.entry))
	kernelMain(&params)
	for {}
	return .SUCCESS
}
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
	headerSize: u64 = size_of(header)
	if f.Read(f, &headerSize, cast(^VOID)&header) != .SUCCESS do return {}, false
	if headerSize != size_of(header) do return
	if !elf.is_valid_elf(header.eIdent) || !elf.is_64bit(header.eIdent) do return {}, false
	if header.machine != .X86_64 do return {}, false
	if header.phnum == 0 || header.phnum > elf.MAX_SEGMENTS do return {}, false

	phdrs: [elf.MAX_SEGMENTS]elf.Phdr

	if f.SetPosition(f, header.phoff) != .SUCCESS do return {}, false
	want := u64(header.phnum) * u64(size_of(elf.Phdr))

	actualSize := want
	if f.Read(f, &actualSize, cast(^VOID)raw_data(phdrs[:])) != .SUCCESS do return {}, false
	if actualSize != want do return {}, false

	minVaddr := ~u64(0)
	maxVaddr: u64 = 0

	foundPhdrs := phdrs[:int(header.phnum)]
	for ph in foundPhdrs {
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
		if f.Read(f, &read, cast(^VOID)uintptr(dest)) != .SUCCESS || read != ph.filesz do return {}, false
		segment: elf.Segment = {
			perms = ph.flags,
			base  = dest,
			end   = dest + ph.memsz,
		}
		append(&image.segments, segment)
	}
	image.entry = header.entry + physBase
	image.base = allocBase + physBase
	image.end = maxVaddr + physBase
	return image, true
}
