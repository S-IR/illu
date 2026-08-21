package pci

PCI_NO_DEVICE :: u16(0xFFFF)
PCI_MULTIFUNCTIONAL :: u8(0x80)

Class :: enum u8 { NETWORK = 0x02 }
Subclass :: enum u8 { ETHERNET = 0x00, WIFI = 0x80 }

Header :: struct #packed {
	vendorId, deviceId, command, status: u16,
	revisionId, progIf: u8,
	subclass: Subclass,
	classCode: Class,
	cacheLineSize, latencyTimer, headerType, bist: u8,
	bar0, bar1, bar2, bar3, bar4, bar5: u32,
}

Bar :: struct { addr, size: u64 }

Device :: struct {
	segment: u16,
	bus, device, function: u8,
	vendorId, deviceId: u16,
	classCode: Class,
	subclass: Subclass,
	progIf: u8,
	configBase: u64,
	bars: [6]Bar,
}
