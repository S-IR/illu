package pci

PCI_NO_DEVICE :: u16(0xFFFF)
PCI_MULTIFUNCTIONAL :: u8(0x80)
CONFIG_SPACE_SIZE :: uintptr(4096)
Class :: enum u8 {
	MASS_STORAGE = 0x01,
	NETWORK      = 0x02,
}
Subclass :: enum u8 {
	ETHERNET = 0x00,
	NVM      = 0x08,
	WIFI     = 0x80,
}
PROG_IF_NVME :: u8(0x02)
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
	capabilities:                         [dynamic; DEVICE_MAX_CAPABILITIES]Capability,
}
DEVICE_MAX_CAPABILITIES :: 48
Capability :: struct #all_or_none {
	id:     u8,
	offset: u8,
}

config_read_u16 :: proc(device: ^Device, offset: uintptr) -> u16 {
	assert(device != nil && offset & 1 == 0 && offset + 2 <= CONFIG_SPACE_SIZE)
	return ecam_read_u16(device.configBase, u64(offset))
}

config_write_u16 :: proc(device: ^Device, offset: uintptr, value: u16) {
	assert(device != nil && offset & 1 == 0 && offset + 2 <= CONFIG_SPACE_SIZE)
	ecam_write_u16(device.configBase, u64(offset), value)
}


CONFIG_COMMAND_OFFSET :: uintptr(0x04)

COMMAND_IO_SPACE :: u16(1 << 0)
COMMAND_MEMORY :: u16(1 << 1)
COMMAND_BUS_MASTER :: u16(1 << 2)
COMMAND_INTX_DISABLE :: u16(1 << 10)
