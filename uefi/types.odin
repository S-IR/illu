/*
 * NOTE: void* fields in structs = not implemented!!
 */

// __has_include is clang/gcc defined; But should be in C standard C2X
package efi

// UEFI 2.10 §2.3.1 https://uefi.org/specifications
UINT8 :: u8
UINT16 :: u16
UINT32 :: u32
UINT64 :: u64
UINTN :: u64
CHAR16 :: u16 // UTF-16, but should use UCS-2 code points 0x0000-0xFFFF
VOID :: rawptr
EFI_STATUS :: enum u64 {
	SUCCESS = 0,
}
EFI_HANDLE :: ^VOID

// UEFI 2.10 Appendix D https://uefi.org/specifications

// UEFI 2.10 §12.4.7 https://uefi.org/specifications
EFI_BLACK :: 0x00
EFI_BLUE :: 0x01
EFI_GREEN :: 0x02
EFI_CYAN :: 0x03
EFI_RED :: 0x04
EFI_YELLOW :: 0x0E
EFI_WHITE :: 0x0F

// UEFI 2.10 §13.5 https://uefi.org/specifications
EFI_FILE_MODE_READ :: 0x0000000000000001

EFI_FILE_INFO_ID :: EFI_GUID {
	0x09576e92,
	0x6d3f,
	0x11d2,
	{0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b},
}

// UEFI 2.10 §7.2 https://uefi.org/specifications
EFI_PHYSICAL_ADDRESS :: UINT64
EFI_VIRTUAL_ADDRESS :: UINT64

// UEFI 2.10 §2.3.1 https://uefi.org/specifications
EFI_GUID :: struct {
	Data1: UINT32,
	Data2: UINT16,
	Data3: UINT16,
	Data4: [8]UINT8,
}

// UEFI 2.10 §4.2 https://uefi.org/specifications
EFI_TABLE_HEADER :: struct {
	Signature:  UINT64,
	Revision:   UINT32,
	HeaderSize: UINT32,
	CRC32:      UINT32,
	Reserved:   UINT32,
}

// UEFI 2.10 §7.2 https://uefi.org/specifications
EFI_MEMORY_DESCRIPTOR :: struct {
	Type:          UINT32,
	PhysicalStart: EFI_PHYSICAL_ADDRESS,
	VirtualStart:  EFI_VIRTUAL_ADDRESS,
	NumberOfPages: UINT64,
	Attribute:     UINT64,
}

// UEFI 2.10 §4.6 https://uefi.org/specifications
// Brought back to root so you can cast and loop through configuration entries
EFI_CONFIGURATION_TABLE :: struct {
	VendorGuid:  EFI_GUID,
	VendorTable: ^VOID,
}

// --- ENUMS (Kept at root for accessibility) ---

EFI_RESET_TYPE :: enum u32 {
	Cold             = 0,
	Warm             = 1,
	Shutdown         = 2,
	PlatformSpecific = 3,
}

EFI_ALLOCATE_TYPE :: enum u32 {
	AllocateAnyPages   = 0,
	AllocateMaxAddress = 1,
	AllocateAddress    = 2,
	MaxAllocateType    = 3,
}

EFI_MEMORY_TYPE :: enum u32 {
	ReservedMemoryType      = 0,
	LoaderCode              = 1,
	LoaderData              = 2,
	BootServicesCode        = 3,
	BootServicesData        = 4,
	RuntimeServicesCode     = 5,
	RuntimeServicesData     = 6,
	ConventionalMemory      = 7,
	UnusableMemory          = 8,
	ACPIReclaimMemory       = 9,
	ACPIMemoryNVS           = 10,
	MemoryMappedIO          = 11,
	MemoryMappedIOPortSpace = 12,
	PalCode                 = 13,
	PersistentMemory        = 14,
	MaxMemoryType           = 15,
}

EFI_GRAPHICS_PIXEL_FORMAT :: enum u32 {
	RedGreenBlueReserved8BitPerColor = 0,
	BlueGreenRedReserved8BitPerColor = 1,
	BitMask                          = 2,
	BltOnly                          = 3,
	FormatMax                        = 4,
}

// --- PROTOCOLS & TABLES (Inlined tree structures) ---

// UEFI 2.10 §12.3 https://uefi.org/specifications
EFI_SIMPLE_TEXT_INPUT_PROTOCOL :: struct {
	Reset:         rawptr,
	ReadKeyStroke: proc "c" (This: ^EFI_SIMPLE_TEXT_INPUT_PROTOCOL, Key: ^struct {
			ScanCode:    UINT16,
			UnicodeChar: CHAR16,
		}) -> EFI_STATUS,
	WaitForKey:    rawptr,
}

// UEFI 2.10 §12.4 https://uefi.org/specifications
EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL :: struct {
	Reset:             rawptr,
	OutputString:      proc "c" (
		This: ^EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL,
		String: ^CHAR16,
	) -> EFI_STATUS,
	TestString:        rawptr,
	QueryMode:         rawptr,
	SetMode:           rawptr,
	SetAttribute:      proc "c" (
		This: ^EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL,
		Attribute: UINTN,
	) -> EFI_STATUS,
	ClearScreen:       proc "c" (This: ^EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL) -> EFI_STATUS,
	SetCursorPosition: rawptr,
	EnableCursor:      rawptr,
	Mode:              rawptr,
}

// UEFI 2.10 §12.9 https://uefi.org/specifications
EFI_GRAPHICS_OUTPUT_PROTOCOL :: struct {
	QueryMode: rawptr,
	SetMode:   rawptr,
	Blt:       rawptr,
	Mode:      ^struct {
		MaxMode:         UINT32,
		Mode:            UINT32,
		Info:            ^struct {
			Version:              UINT32,
			HorizontalResolution: UINT32,
			VerticalResolution:   UINT32,
			PixelFormat:          EFI_GRAPHICS_PIXEL_FORMAT,
			PixelInformation:     struct {
				RedMask:      UINT32,
				GreenMask:    UINT32,
				BlueMask:     UINT32,
				ReservedMask: UINT32,
			},
			PixelsPerScanLine:    UINT32,
		},
		SizeOfInfo:      UINTN,
		FrameBufferBase: EFI_PHYSICAL_ADDRESS,
		FrameBufferSize: UINTN,
	},
}

// UEFI 2.10 §13.5 https://uefi.org/specifications
EFI_FILE_PROTOCOL :: struct {
	Revision:    UINT64,
	Open:        proc "c" (
		This: ^EFI_FILE_PROTOCOL,
		NewHandle: ^^EFI_FILE_PROTOCOL,
		FileName: ^CHAR16,
		OpenMode: UINT64,
		Attributes: UINT64,
	) -> EFI_STATUS,
	Close:       proc "c" (This: ^EFI_FILE_PROTOCOL) -> EFI_STATUS,
	Delete:      rawptr,
	Read:        proc "c" (
		This: ^EFI_FILE_PROTOCOL,
		BufferSize: ^UINTN,
		Buffer: ^VOID,
	) -> EFI_STATUS,
	Write:       rawptr,
	GetPosition: rawptr,
	SetPosition: proc "c" (This: ^EFI_FILE_PROTOCOL, Position: u64) -> EFI_STATUS,
	GetInfo:     proc "c" (
		This: ^EFI_FILE_PROTOCOL,
		InformationType: ^EFI_GUID,
		BufferSize: ^UINTN,
		Buffer: ^VOID,
	) -> EFI_STATUS,
	SetInfo:     rawptr,
	Flush:       rawptr,
}

// UEFI 2.10 §13.4 https://uefi.org/specifications
EFI_SIMPLE_FILE_SYSTEM_PROTOCOL :: struct {
	Revision:   UINT64,
	OpenVolume: proc "c" (
		This: ^EFI_SIMPLE_FILE_SYSTEM_PROTOCOL,
		Root: ^^EFI_FILE_PROTOCOL,
	) -> EFI_STATUS,
}

// UEFI 2.10 §9.1 https://uefi.org/specifications
EFI_LOADED_IMAGE_PROTOCOL :: struct {
	Revision:        UINT32,
	ParentHandle:    EFI_HANDLE,
	SystemTable:     ^EFI_SYSTEM_TABLE,
	DeviceHandle:    EFI_HANDLE,
	FilePath:        rawptr,
	Reserved:        rawptr,
	LoadOptionsSize: UINT32,
	LoadOptions:     rawptr,
	ImageBase:       rawptr,
	ImageSize:       UINT64,
}

// UEFI 2.10 §7.1 https://uefi.org/specifications
EFI_BOOT_SERVICES :: struct {
	Hdr:                                 EFI_TABLE_HEADER,
	RaiseTPL:                            rawptr,
	RestoreTPL:                          rawptr,
	AllocatePages:                       proc "c" (
		Type: EFI_ALLOCATE_TYPE,
		MemoryType: EFI_MEMORY_TYPE,
		Pages: UINTN,
		Memory: ^EFI_PHYSICAL_ADDRESS,
	) -> EFI_STATUS,
	FreePages:                           rawptr,
	GetMemoryMap:                        proc "c" (
		MemoryMapSize: ^UINTN,
		MemoryMap: ^EFI_MEMORY_DESCRIPTOR,
		MapKey: ^UINTN,
		DescriptorSize: ^UINTN,
		DescriptorVersion: ^UINT32,
	) -> EFI_STATUS,
	AllocatePool:                        proc "c" (
		PoolType: EFI_MEMORY_TYPE,
		Size: UINTN,
		Buffer: ^rawptr,
	) -> EFI_STATUS,
	FreePool:                            proc "c" (Buffer: rawptr) -> EFI_STATUS,
	CreateEvent:                         rawptr,
	SetTimer:                            rawptr,
	WaitForEvent:                        rawptr,
	SignalEvent:                         rawptr,
	CloseEvent:                          rawptr,
	CheckEvent:                          rawptr,
	InstallProtocolInterface:            rawptr,
	ReinstallProtocolInterface:          rawptr,
	UninstallProtocolInterface:          rawptr,
	HandleProtocol:                      proc "c" (
		Handle: EFI_HANDLE,
		Protocol: ^EFI_GUID,
		Interface: ^^VOID,
	) -> EFI_STATUS,
	Reserved:                            rawptr,
	RegisterProtocolNotify:              rawptr,
	LocateHandle:                        rawptr,
	LocateDevicePath:                    rawptr,
	InstallConfigurationTable:           rawptr,
	LoadImage:                           proc "c" (
		BootPolicy: bool,
		ParentImageHandle: EFI_HANDLE,
		DevicePath: ^EFI_DEVICE_PATH_PROTOCOL,
		SourceBuffer: rawptr,
		SourceSize: UINTN,
		ImageHandle: ^EFI_HANDLE,
	) -> EFI_STATUS,
	StartImage:                          proc "c" (
		ImageHandle: EFI_HANDLE,
		ExitDataSize: ^UINTN,
		ExitData: ^^CHAR16,
	) -> EFI_STATUS,
	Exit:                                rawptr,
	UnloadImage:                         rawptr,
	ExitBootServices:                    proc "c" (
		ImageHandle: EFI_HANDLE,
		MapKey: UINTN,
	) -> EFI_STATUS,
	GetNextMonotonicCount:               rawptr,
	Stall:                               rawptr,
	SetWatchdogTimer:                    rawptr,
	ConnectController:                   rawptr,
	DisconnectController:                rawptr,
	OpenProtocol:                        rawptr,
	CloseProtocol:                       rawptr,
	OpenProtocolInformation:             rawptr,
	ProtocolsPerHandle:                  rawptr,
	LocateHandleBuffer:                  rawptr,
	LocateProtocol:                      proc "c" (
		Protocol: ^EFI_GUID,
		Registration: ^VOID,
		Interface: ^^VOID,
	) -> EFI_STATUS,
	InstallMultipleProtocolInterfaces:   rawptr,
	UninstallMultipleProtocolInterfaces: rawptr,
	CalculateCrc32:                      rawptr,
	CopyMem:                             rawptr,
	SetMem:                              rawptr,
	CreateEventEx:                       rawptr,
}

// UEFI 2.10 §8.1 https://uefi.org/specifications
EFI_RUNTIME_SERVICES :: struct {
	Hdr:                       EFI_TABLE_HEADER,
	GetTime:                   rawptr,
	SetTime:                   rawptr,
	GetWakeupTime:             rawptr,
	SetWakeupTime:             rawptr,
	SetVirtualAddressMap:      rawptr,
	ConvertPointer:            rawptr,
	GetVariable:               rawptr,
	GetNextVariableName:       rawptr,
	SetVariable:               rawptr,
	GetNextHighMonotonicCount: rawptr,
	ResetSystem:               proc "c" (
		ResetType: EFI_RESET_TYPE,
		ResetStatus: EFI_STATUS,
		DataSize: UINTN,
		ResetData: ^VOID,
	) -> VOID,
	UpdateCapsule:             rawptr,
	QueryCapsuleCapabilities:  rawptr,
	QueryVariableInfo:         rawptr,
}

// UEFI 2.10 §4.3 https://uefi.org/specifications
EFI_SYSTEM_TABLE :: struct {
	Hdr:                  EFI_TABLE_HEADER,
	FirmwareVendor:       rawptr,
	FirmwareRevision:     UINT32,
	ConsoleInHandle:      rawptr,
	ConIn:                ^EFI_SIMPLE_TEXT_INPUT_PROTOCOL,
	ConsoleOutHandle:     rawptr,
	ConOut:               ^EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL,
	StandardErrorHandle:  rawptr,
	StdErr:               rawptr,
	RuntimeServices:      ^EFI_RUNTIME_SERVICES,
	BootServices:         ^EFI_BOOT_SERVICES,
	NumberOfTableEntries: UINTN,
	ConfigurationTable:   ^EFI_CONFIGURATION_TABLE, // Clean named pointer reference!
}

// UEFI 2.10 §13.5.17 https://uefi.org/specifications
EFI_FILE_INFO :: struct {
	Size:             UINT64,
	FileSize:         UINT64,
	PhysicalSize:     UINT64,
	CreateTime:       [16]u8,
	LastAccessTime:   [16]u8,
	ModificationTime: [16]u8,
	Attribute:        UINT64,
}
EFI_DEVICE_PATH_PROTOCOL :: struct {
	Type:    u8,
	SubType: u8,
	Length:  [2]u8,
}

EFI_DEVICE_PATH_UTILITIES_PROTOCOL_GUID := EFI_GUID {
	0x379be50f,
	0x4d8d,
	0x4855,
	{0x86, 0x69, 0x1a, 0x14, 0x66, 0x24, 0x98, 0x65},
}

EFI_DEVICE_PATH_UTILITIES_PROTOCOL :: struct {
	CreateDeviceNode: proc "c" (
		NodeType: u8,
		NodeSubType: u8,
		NodeLength: u16,
	) -> ^EFI_DEVICE_PATH_PROTOCOL,
	AppendNode:       proc "c" (
		DevicePath: ^EFI_DEVICE_PATH_PROTOCOL,
		DeviceNode: ^EFI_DEVICE_PATH_PROTOCOL,
	) -> ^EFI_DEVICE_PATH_PROTOCOL,
	// Other fields omitted
}
GOP_GUID := EFI_GUID{0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}}
FS_GUID := EFI_GUID{0x964e5b22, 0x6459, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
LIP_GUID := EFI_GUID{0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
ACPI2_GUID := EFI_GUID {
	0x8868e871,
	0xe4f1,
	0x11d3,
	{0xbc, 0x22, 0x00, 0x80, 0xc7, 0x73, 0xc8, 0x81},
}
ACPI1_GUID := EFI_GUID {
	0xeb9d2d30,
	0x2d88,
	0x11d3,
	{0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d},
}

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
	'f',
	'i',
	'l',
	'e',
	' ',
	'r',
	'e',
	'a',
	'd',
	'i',
	'n',
	'g',
	' ',
	'e',
	'r',
	'r',
	'o',
	'r',
	'\r',
	'\n',
	0,
}

errOOM := [?]u16{'o', 'u', 't', ' ', 'o', 'f', ' ', 'm', 'e', 'm', 'o', 'r', 'y', '\r', '\n', 0}
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
@(export, link_name = "_fltused")
_fltused: i32 = 1

@(export, link_name = "_tls_index")
_tls_index: u32 = 0

@(export, link_name = "memcpy")
memcpy :: proc "c" (dst, src: rawptr, n: uint) -> rawptr {
	d := ([^]u8)(dst)
	s := ([^]u8)(src)
	for i in 0 ..< n do d[i] = s[i]
	return dst
}

@(export, link_name = "memset")
memset :: proc "c" (dst: rawptr, val: i32, n: uint) -> rawptr {
	d := ([^]u8)(dst)
	for i in 0 ..< n do d[i] = u8(val)
	return dst
}

@(export, link_name = "memmove")
memmove :: proc "c" (dst, src: rawptr, n: uint) -> rawptr {
	d := ([^]u8)(dst)
	s := ([^]u8)(src)
	if uintptr(dst) < uintptr(src) {
		for i in 0 ..< n do d[i] = s[i]
	} else {
		for i := n; i > 0; i -= 1 do d[i - 1] = s[i - 1]
	}
	return dst
}
