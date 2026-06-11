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
import sh "../lib/shared"
FrameBuffer :: struct {
	base:   [^]u32,
	width:  u64,
	height: u64,
	stride: u64,
}

KernelParams :: struct #all_or_none {
	fb:                sh.FrameBuffer,
	rsdp:              rawptr,
	memoryMap:         [^]EFI_MEMORY_DESCRIPTOR,
	memoryMapSize:     u64,
	memoryMapDescSize: u64,
	kernelBase:        u64, // image span [base, end); entry may differ from base
	kernelEntry:       u64,
	kernelEnd:         u64,
	kernelRoEnd:       u64, // [kernelBase, kernelRoEnd) = text/rodata, safe to map read-only
	fsBase:            u64,
	fsEntry:           u64,
	fsEnd:             u64,
	fsRoEnd:           u64, // [fsBase, fsRoEnd) = text/rodata, mapped RX; rest RW
	cr3:               u64,
}

gop_guid := EFI_GUID{0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}}
fs_guid := EFI_GUID{0x964e5b22, 0x6459, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
lip_guid := EFI_GUID{0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
acpi2_guid := EFI_GUID {
	0x8868e871,
	0xe4f1,
	0x11d3,
	{0xbc, 0x22, 0x00, 0x80, 0xc7, 0x73, 0xc8, 0x81},
}
acpi1_guid := EFI_GUID {
	0xeb9d2d30,
	0x2d88,
	0x11d3,
	{0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d},
}

mmapBuf: [4096 * 10]u8

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
efi_main :: proc "win64" (
	image_handle: EFI_HANDLE,
	system_table: ^EFI_SYSTEM_TABLE,
) -> EFI_STATUS {
	errGop := [?]u16{'n', 'o', ' ', 'G', 'O', 'P', '\r', '\n', 0}
	errLip := [?]u16 {
		'n',
		'o',
		' ',
		'l',
		'o',
		'a',
		'd',
		'e',
		'd',
		' ',
		'i',
		'm',
		'a',
		'g',
		'e',
		'\r',
		'\n',
		0,
	}
	errFs := [?]u16 {
		'n',
		'o',
		' ',
		'b',
		'o',
		'o',
		't',
		' ',
		'v',
		'o',
		'l',
		'u',
		'm',
		'e',
		'\r',
		'\n',
		0,
	}
	errKernel := [?]u16 {
		'k',
		'e',
		'r',
		'n',
		'e',
		'l',
		' ',
		'l',
		'o',
		'a',
		'd',
		' ',
		'f',
		'a',
		'i',
		'l',
		'e',
		'd',
		'\r',
		'\n',
		0,
	}
	errDaemon := [?]u16 {
		'f',
		's',
		'_',
		'd',
		'a',
		'e',
		'm',
		'o',
		'n',
		' ',
		'l',
		'o',
		'a',
		'd',
		' ',
		'f',
		'a',
		'i',
		'l',
		'e',
		'd',
		'\r',
		'\n',
		0,
	}
	errMmap := [?]u16 {
		'G',
		'e',
		't',
		'M',
		'e',
		'm',
		'o',
		'r',
		'y',
		'M',
		'a',
		'p',
		' ',
		'f',
		'a',
		'i',
		'l',
		'e',
		'd',
		'\r',
		'\n',
		0,
	}
	errRsdp := [?]u16{'n', 'o', ' ', 'A', 'C', 'P', 'I', ' ', 'R', 'S', 'D', 'P', '\r', '\n', 0}

	// UEFI 2.10 §7.3.16 LocateProtocol https://uefi.org/specifications
	gop: ^EFI_GRAPHICS_OUTPUT_PROTOCOL
	if system_table.BootServices.LocateProtocol(&gop_guid, nil, cast(^^VOID)&gop) != EFI_SUCCESS ||
	   gop == nil ||
	   gop.Mode == nil ||
	   gop.Mode.Info == nil {
		boot_fail(system_table, &errGop[0])
	}

	// UEFI 2.10 §7.3.5 HandleProtocol https://uefi.org/specifications
	loadedImage: ^EFI_LOADED_IMAGE_PROTOCOL
	if system_table.BootServices.HandleProtocol(
		   image_handle,
		   &lip_guid,
		   cast(^^VOID)&loadedImage,
	   ) !=
		   EFI_SUCCESS ||
	   loadedImage == nil {
		boot_fail(system_table, &errLip[0])
	}

	// UEFI 2.10 §7.3.5 HandleProtocol https://uefi.org/specifications
	fs: ^EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
	if system_table.BootServices.HandleProtocol(
		   loadedImage.DeviceHandle,
		   &fs_guid,
		   cast(^^VOID)&fs,
	   ) !=
		   EFI_SUCCESS ||
	   fs == nil {
		boot_fail(system_table, &errFs[0])
	}

	// UEFI 2.10 §13.4.2 OpenVolume https://uefi.org/specifications
	root: ^EFI_FILE_PROTOCOL
	if fs.OpenVolume(fs, &root) != EFI_SUCCESS || root == nil {
		boot_fail(system_table, &errFs[0])
	}

	kernelName := [?]u16{'k', 'e', 'r', 'n', 'e', 'l', '.', 'e', 'l', 'f', 0}
	fsDaemonName := [?]u16{'f', 's', '_', 'd', 'a', 'e', 'm', 'o', 'n', '.', 'e', 'l', 'f', 0}

	kernelImg, kernelOk := load_elf(root, &kernelName[0], system_table.BootServices)
	if !kernelOk do boot_fail(system_table, &errKernel[0])
	fsImg, fsOk := load_elf(root, &fsDaemonName[0], system_table.BootServices, pie = true)
	if !fsOk do boot_fail(system_table, &errDaemon[0])

	// UEFI 2.10 §4.6 ConfigurationTable — scan for ACPI RSDP https://uefi.org/specifications
	rsdp: rawptr = nil
	configTable := cast([^]EFI_CONFIGURATION_TABLE)system_table.ConfigurationTable
	for i in 0 ..< system_table.NumberOfTableEntries {
		t := &configTable[i]
		if guid_equal(&t.VendorGuid, &acpi2_guid) {
			rsdp = rawptr(t.VendorTable)
			break
		}
		if guid_equal(&t.VendorGuid, &acpi1_guid) && rsdp == nil {
			rsdp = rawptr(t.VendorTable)
		}
	}
	if rsdp == nil do boot_fail(system_table, &errRsdp[0])

	// UEFI 2.10 §7.2.3 GetMemoryMap https://uefi.org/specifications
	mmapSize: u64 = size_of(mmapBuf)
	mapKey: u64 = 0
	descSize: u64 = 0
	descVer: u32 = 0
	if system_table.BootServices.GetMemoryMap(
		   &mmapSize,
		   cast(^EFI_MEMORY_DESCRIPTOR)&mmapBuf[0],
		   &mapKey,
		   &descSize,
		   &descVer,
	   ) !=
	   EFI_SUCCESS {
		boot_fail(system_table, &errMmap[0])
	}
	if descSize == 0 || mmapSize == 0 || mmapSize > size_of(mmapBuf) {
		boot_fail(system_table, &errMmap[0])
	}

	// UEFI 2.10 §7.4.6 ExitBootServices — mapKey goes stale if firmware allocates
	// between GetMemoryMap and ExitBootServices; spec says retry with a fresh map.
	// After the first failed attempt ConOut is gone, so failures here can't print.
	for system_table.BootServices.ExitBootServices(image_handle, mapKey) != EFI_SUCCESS {
		mmapSize = size_of(mmapBuf)
		if system_table.BootServices.GetMemoryMap(
			   &mmapSize,
			   cast(^EFI_MEMORY_DESCRIPTOR)&mmapBuf[0],
			   &mapKey,
			   &descSize,
			   &descVer,
		   ) !=
		   EFI_SUCCESS {
			for {}
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
		memoryMap = cast([^]EFI_MEMORY_DESCRIPTOR)&mmapBuf[0],
		memoryMapSize = u64(mmapSize),
		memoryMapDescSize = u64(descSize),
		kernelBase = kernelImg.base,
		kernelEntry = kernelImg.entry,
		kernelEnd = kernelImg.end,
		kernelRoEnd = kernelImg.roEnd,
		fsBase = fsImg.base,
		fsEntry = fsImg.entry,
		fsEnd = fsImg.end,
		fsRoEnd = fsImg.roEnd,
		cr3 = 0,
	}

	KernelEntry :: #type proc "sysv" (params: ^KernelParams)
	kernelMain := cast(KernelEntry)rawptr(uintptr(kernelImg.entry))
	kernelMain(&params)

	for {}
	return EFI_SUCCESS
}
