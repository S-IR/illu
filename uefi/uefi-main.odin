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

package uefi
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
	if systemTable.BootServices.LocateProtocol(&GOP_GUID, nil, auto_cast &gop) != .SUCCESS ||
	   gop == nil ||
	   gop.Mode == nil ||
	   gop.Mode.Info == nil {
		boot_fail(systemTable, &errGop[0])
	}

	// UEFI 2.10 §7.3.5 HandleProtocol https://uefi.org/specifications
	loadedImage: ^EFI_LOADED_IMAGE_PROTOCOL
	if systemTable.BootServices.HandleProtocol(imageHandle, &LIP_GUID, auto_cast &loadedImage) !=
		   .SUCCESS ||
	   loadedImage == nil {
		boot_fail(systemTable, &errLip[0])
	}


	// UEFI 2.10 §7.3.5 HandleProtocol https://uefi.org/specifications
	fs: ^EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
	if systemTable.BootServices.HandleProtocol(
		   loadedImage.DeviceHandle,
		   &FS_GUID,
		   auto_cast &fs,
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
