package pci

import "../acpi"
import "base:intrinsics"

enumerate :: proc "contextless" (rsdp: ^acpi.Rsdp, out: []Device) -> (count: int) {
	mcfg := acpi.find_table(rsdp, {'M', 'C', 'F', 'G'})
	if mcfg == nil do return 0

	entriesOffset := size_of(acpi.Header) + 8
	if int(mcfg.length) < entriesOffset do return 0
	entryCount := (int(mcfg.length) - entriesOffset) / size_of(acpi.McfgEntry)
	entries := ([^]acpi.McfgEntry)(uintptr(rawptr(mcfg)) + uintptr(entriesOffset))

	for entry in entries[:entryCount] {
		for bus in int(entry.startBus) ..= int(entry.endBus) {
			for device in u8(0) ..< 32 {
				header0 := ecam_address(entry, u8(bus), device, 0)
				if ecam_read_u16(header0, 0x00) == PCI_NO_DEVICE do continue
				functionCount := u8(1)
				if ecam_read_u8(header0, 0x0E) & PCI_MULTIFUNCTIONAL != 0 do functionCount = 8
				for function in u8(0) ..< functionCount {
					header := ecam_address(entry, u8(bus), device, function)
					if ecam_read_u16(header, 0x00) == PCI_NO_DEVICE do continue
					if count < len(out) {
						out[count] = device_read(entry.segmentGroup, u8(bus), device, function, header)
					}
					count += 1
				}
			}
		}
	}
	return count
}

@(private)
device_read :: proc "contextless" (segment: u16, bus, device, function: u8, header: u64) -> Device {
	info := Device {
		segment           = segment,
		bus               = bus,
		device            = device,
		function          = function,
		vendorId          = ecam_read_u16(header, 0x00),
		deviceId          = ecam_read_u16(header, 0x02),
		classCode         = Class(ecam_read_u8(header, 0x0B)),
		subclass          = Subclass(ecam_read_u8(header, 0x0A)),
		progIf            = ecam_read_u8(header, 0x09),
		configBase        = header,
		revisionId        = ecam_read_u8(header, 0x08),
		headerType        = ecam_read_u8(header, 0x0E),
		command           = ecam_read_u16(header, 0x04),
		status            = ecam_read_u16(header, 0x06),
		subsystemVendorId = ecam_read_u16(header, 0x2C),
		subsystemDeviceId = ecam_read_u16(header, 0x2E),
		interruptLine     = ecam_read_u8(header, 0x3C),
		interruptPin      = ecam_read_u8(header, 0x3D),
		bars              = {},
		capabilitiesPtr   = ecam_read_u8(header, 0x34),
		capabilityCount   = 0,
		capabilities      = {},
	}
	info.capabilityCount = capabilities_read(header, &info.capabilities)

	barCount: u32 = 6
	if info.headerType & 0x7F == 0x01 do barCount = 2
	for index: u32 = 0; index < barCount; index += 1 {
		low := bar_read(header, index)
		if low == 0 do continue
		isMemory := low & 1 == 0
		is64 := isMemory && (low >> 1) & 0x3 == 0x2 && index + 1 < barCount
		high: u32 = 0
		if is64 do high = bar_read(header, index + 1)
		bar := Bar {
			addr         = u64(high) << 32 | u64(low & (0xFFFF_FFF0 if isMemory else 0xFFFF_FFFC)),
			size         = bar_size(header, index, is64),
			isMemory     = isMemory,
			is64Bit      = is64,
			prefetchable = isMemory && (low >> 3) & 1 != 0,
		}
		if bar_valid(bar) do info.bars[index] = bar
		if is64 do index += 1
	}
	return info
}

@(private)
ecam_address :: proc "contextless" (entry: acpi.McfgEntry, bus, device, function: u8) -> u64 {
	assert_contextless(bus >= entry.startBus && bus <= entry.endBus)
	assert_contextless(device < 32 && function < 8)
	return(
		entry.baseAddr +
		u64(bus - entry.startBus) << 20 +
		u64(device) << 15 +
		u64(function) << 12 \
	)
}

@(private)
ecam_read_u8 :: proc "contextless" (header: u64, offset: u64) -> u8 {
	return intrinsics.volatile_load((^u8)(uintptr(header + offset)))
}

@(private)
ecam_read_u16 :: proc "contextless" (header: u64, offset: u64) -> u16 {
	return intrinsics.volatile_load((^u16)(uintptr(header + offset)))
}

@(private)
ecam_read_u32 :: proc "contextless" (header: u64, offset: u64) -> u32 {
	return intrinsics.volatile_load((^u32)(uintptr(header + offset)))
}

@(private)
ecam_write_u16 :: proc "contextless" (header: u64, offset: u64, value: u16) {
	intrinsics.volatile_store((^u16)(uintptr(header + offset)), value)
}

@(private)
ecam_write_u32 :: proc "contextless" (header: u64, offset: u64, value: u32) {
	intrinsics.volatile_store((^u32)(uintptr(header + offset)), value)
}

@(private)
bar_read :: proc "contextless" (header: u64, index: u32) -> u32 {
	return ecam_read_u32(header, 0x10 + u64(index) * 4)
}

@(private)
bar_write :: proc "contextless" (header: u64, index: u32, value: u32) {
	ecam_write_u32(header, 0x10 + u64(index) * 4, value)
}

@(private)
bar_size :: proc "contextless" (header: u64, index: u32, is64: bool) -> u64 {
	low := bar_read(header, index)
	high: u32 = 0
	if is64 do high = bar_read(header, index + 1)
	command := ecam_read_u16(header, u64(CONFIG_COMMAND_OFFSET))
	disabledCommand := command & ~(COMMAND_IO_SPACE | COMMAND_MEMORY | COMMAND_BUS_MASTER)
	ecam_write_u16(header, u64(CONFIG_COMMAND_OFFSET), disabledCommand)
	bar_write(header, index, 0xFFFF_FFFF)
	if is64 do bar_write(header, index + 1, 0xFFFF_FFFF)
	maskLow := bar_read(header, index)
	mask := u64(maskLow & (0xFFFF_FFF0 if maskLow & 1 == 0 else 0xFFFF_FFFC))
	if is64 do mask |= u64(bar_read(header, index + 1)) << 32
	if is64 do bar_write(header, index + 1, high)
	bar_write(header, index, low)
	ecam_write_u16(header, u64(CONFIG_COMMAND_OFFSET), command)
	if mask == 0 do return 0
	return ~mask + 1
}

@(private)
bar_valid :: proc "contextless" (bar: Bar) -> bool {
	if bar.addr == 0 || bar.size == 0 do return false
	if bar.size & (bar.size - 1) != 0 do return false
	if bar.addr & (bar.size - 1) != 0 do return false
	return bar.addr + bar.size >= bar.addr
}

@(private)
capabilities_read :: proc "contextless" (header: u64, out: ^[64]Capability) -> (count: u8) {
	ptr := ecam_read_u8(header, 0x34)
	seen: [256]bool
	for ptr != 0 && int(count) < len(out) {
		if ptr < 0x40 || ptr >= 0xFE || seen[ptr] do break
		seen[ptr] = true
		capHeader := ecam_read_u16(header, u64(ptr))
		out[count] = Capability {
			id     = u8(capHeader & 0xFF),
			offset = ptr,
		}
		count += 1
		ptr = u8(capHeader >> 8)
	}
	return count
}
