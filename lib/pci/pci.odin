package pci

PCI_NO_DEVICE :: u16(0xFFFF)
PCI_MULTIFUNCTIONAL :: u8(0x80)

Class :: enum u8 {
	NETWORK = 0x02,
}
Subclass :: enum u8 {
	ETHERNET = 0x00,
	WIFI     = 0x80,
}

Header :: struct #packed {
	vendorId, deviceId, command, status:              u16,
	revisionId, progIf:                               u8,
	subclass:                                         Subclass,
	classCode:                                        Class,
	cacheLineSize, latencyTimer, headerType, bist:    u8,
	bar0, bar1, bar2, bar3, bar4, bar5:               u32,
	cardbusCisPointer:                                u32,
	subsystemVendorId, subsystemDeviceId:             u16,
	expansionRom:                                     u32,
	capabilitiesPtr, reserved0, reserved1, reserved2: u8,
	interruptLine, interruptPin:                      u8,
	minGrant, maxLatency:                             u8,
}

Bar :: struct #all_or_none {
	addr:         u64,
	size:         u64,
	isMemory:     bool,
	is64Bit:      bool,
	prefetchable: bool,
}

Device :: struct #all_or_none {
	segment:                              u16,
	bus, device, function:                u8,
	vendorId, deviceId:                   u16,
	classCode:                            Class,
	subclass:                             Subclass,
	progIf:                               u8,
	configBase:                           u64,
	revisionId:                           u8,
	headerType:                           u8,
	command, status:                      u16,
	subsystemVendorId, subsystemDeviceId: u16,
	interruptLine, interruptPin:          u8,
	bars:                                 [6]Bar,
	capabilitiesPtr:                      u8,
	capabilityCount:                      u8,
	capabilities:                         [64]Capability,
}
Capability :: struct #all_or_none {
	id:     u8,
	offset: u8,
}

config_read_u16 :: proc(device: ^Device, offset: uintptr) -> u16 {
	return (^u16)(uintptr(device.configBase) + offset)^
}

config_read_u32 :: proc(device: ^Device, offset: uintptr) -> u32 {
	return (^u32)(uintptr(device.configBase) + offset)^
}

config_write_u16 :: proc(device: ^Device, offset: uintptr, value: u16) {
	(^u16)(uintptr(device.configBase) + offset)^ = value
}

config_write_u32 :: proc(device: ^Device, offset: uintptr, value: u32) {
	(^u32)(uintptr(device.configBase) + offset)^ = value
}


CONFIG_COMMAND_OFFSET :: uintptr(0x04)

COMMAND_IO_SPACE :: u16(1 << 0)
COMMAND_MEMORY :: u16(1 << 1)
COMMAND_BUS_MASTER :: u16(1 << 2)
CAPABILITY_MSI :: u8(0x05)

find_capability :: proc(device: ^Device, id: u8) -> (offset: u8, found: bool) {
	for i in 0 ..< int(device.capabilityCount) {
		capability := device.capabilities[i]

		if capability.id == id do return capability.offset, true

	}
	return 0, false
}


MSI_CONTROL :: uintptr(0x02)
MSI_MESSAGE_ADDR :: uintptr(0x04)
MSI_MESSAGE_DATA32 :: uintptr(0x08)
MSI_MESSAGE_DATA64 :: uintptr(0x0C)

MSI_CONTROL_ENABLE :: u16(1 << 0)
MSI_CONTROL_64BIT :: u16(1 << 7)
MSI_CONTROL_MASK_CAPABLE :: u16(1 << 8)
