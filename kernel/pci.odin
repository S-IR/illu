package kernel

import "../lib/acpi"
import "../lib/pci"
import "../lib/shared"
import ah "../asm_helpers"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"

find_pci_devices :: proc(rsdp: ^acpi.Rsdp) -> (devices: [dynamic]pci.Device) {
	devices = make([dynamic]pci.Device)
	mcfg := acpi.find_table(rsdp, {'M', 'C', 'F', 'G'})
	print.kensure(mcfg != nil, "PCI MCFG table missing")
	if mcfg == nil do return devices

	baseOffset := size_of(acpi.Header) + 8
	print.kensure(mcfg.length >= u32(baseOffset), "PCI MCFG table is too short")
	if mcfg.length < u32(baseOffset) do return devices
	entryCount := (int(mcfg.length) - baseOffset) / size_of(acpi.McfgEntry)
	entries := ([^]acpi.McfgEntry)(intrinsics.ptr_offset((^u8)(rawptr(mcfg)), baseOffset))

	for entryIndex in 0 ..< entryCount {
		entry := entries[entryIndex]
		if entry.startBus > entry.endBus do continue
		for bus in entry.startBus ..= entry.endBus {
			busBase := entry.baseAddr + (u64(bus - entry.startBus) << 20)
			for offset := u64(0); offset < u64(mem.Megabyte); offset += shared.PAGE_SIZE {
				pmm.map_page(
					pmm.kernelPML4,
					busBase + offset,
					._4KB,
					{.Present, .Write, .PWT, .PCD, .NX},
				)
			}
			for device in u8(0) ..< 32 {
				functionCount := u8(1)
				header0 := kernel_pci_header(entry.baseAddr, entry.startBus, bus, device, 0)
				if kernel_pci_read_u16(header0, 0x00) == pci.PCI_NO_DEVICE do continue
				if kernel_pci_read_u8(header0, 0x0E) & pci.PCI_MULTIFUNCTIONAL != 0 do functionCount = 8
				for function in u8(0) ..< functionCount {
					header := kernel_pci_header(
						entry.baseAddr,
						entry.startBus,
						bus,
						device,
						function,
					)
					if kernel_pci_read_u16(header, 0x00) == pci.PCI_NO_DEVICE do continue
					barCount: u32 = 6
					if (kernel_pci_read_u8(header, 0x0E) & 0x7F) == 0x01 do barCount = 2
					info := pci.Device {
						segment           = entry.segmentGroup,
						bus               = bus,
						device            = device,
						function          = function,
						vendorId          = kernel_pci_read_u16(header, 0x00),
						deviceId          = kernel_pci_read_u16(header, 0x02),
						classCode         = pci.Class(kernel_pci_read_u8(header, 0x0B)),
						subclass          = pci.Subclass(kernel_pci_read_u8(header, 0x0A)),
						progIf            = kernel_pci_read_u8(header, 0x09),
						configBase        = u64(uintptr(header)),
						revisionId        = kernel_pci_read_u8(header, 0x08),
						headerType        = kernel_pci_read_u8(header, 0x0E),
						command           = kernel_pci_read_u16(header, 0x04),
						status            = kernel_pci_read_u16(header, 0x06),
						subsystemVendorId = kernel_pci_read_u16(header, 0x2C),
						subsystemDeviceId = kernel_pci_read_u16(header, 0x2E),
						interruptLine     = kernel_pci_read_u8(header, 0x3C),
						interruptPin      = kernel_pci_read_u8(header, 0x3D),
						bars              = {},
						capabilitiesPtr   = kernel_pci_read_u8(header, 0x34),
						capabilityCount   = 0,
						capabilities      = {},
					}
					info.capabilityCount = kernel_pci_capabilities(header, &info.capabilities)

					index: u32 = 0
					for index < barCount {
						low := kernel_pci_bar_read(header, index)
						defer index += 1
						if low == 0 do continue
						isMemory := (low & 1) == 0
						is64 := isMemory && ((low >> 1) & 0x3) == 0x2 && (index + 1) < barCount
						high: u32 = 0
						if is64 do high = kernel_pci_bar_read(header, index + 1)
						bar := pci.Bar {
							addr         = (u64(high) <<
								32) | u64(low & (0xFFFF_FFF0 if isMemory else 0xFFFF_FFFC)),
							size         = kernel_pci_bar_size(header, index, is64),
							isMemory     = isMemory,
							is64Bit      = is64,
							prefetchable = isMemory && ((low >> 3) & 1) != 0,
						}
						if kernel_pci_bar_valid(bar) do info.bars[index] = bar
						if is64 do index += 1
					}
					append(&devices, info)
				}
			}
		}
	}
	return devices
}

kernel_pci_header :: proc(base: u64, start, bus, device, function: u8) -> ^pci.Header {
	address := base + (u64(bus - start) << 20) + (u64(device) << 15) + (u64(function) << 12)
	return (^pci.Header)(uintptr(address))
}

kernel_pci_read_u8 :: proc(header: ^pci.Header, offset: uintptr) -> u8 {
	return ah.mmio_read_u8(rawptr(uintptr(header) + offset))
}

kernel_pci_read_u16 :: proc(header: ^pci.Header, offset: uintptr) -> u16 {
	return ah.mmio_read_u16(rawptr(uintptr(header) + offset))
}

kernel_pci_read_u32 :: proc(header: ^pci.Header, offset: uintptr) -> u32 {
	return ah.mmio_read_u32(rawptr(uintptr(header) + offset))
}

kernel_pci_write_u32 :: proc(header: ^pci.Header, offset: uintptr, value: u32) {
	ah.mmio_write_u32(rawptr(uintptr(header) + offset), value)
}

kernel_pci_bar_read :: proc(header: ^pci.Header, index: u32) -> u32 {
	return kernel_pci_read_u32(header, uintptr(0x10) + uintptr(index * 4))
}

kernel_pci_bar_write :: proc(header: ^pci.Header, index: u32, value: u32) {
	kernel_pci_write_u32(header, uintptr(0x10) + uintptr(index * 4), value)
}

kernel_pci_bar_size :: proc(header: ^pci.Header, index: u32, is64: bool) -> u64 {
	low := kernel_pci_bar_read(header, index)
	high: u32 = 0
	if is64 do high = kernel_pci_bar_read(header, index + 1)
	kernel_pci_bar_write(header, index, 0xFFFF_FFFF)
	if is64 do kernel_pci_bar_write(header, index + 1, 0xFFFF_FFFF)
	maskLow := kernel_pci_bar_read(header, index)
	mask := u64(maskLow & (0xFFFF_FFF0 if (maskLow & 1) == 0 else 0xFFFF_FFFC))
	if is64 do mask |= u64(kernel_pci_bar_read(header, index + 1)) << 32
	kernel_pci_bar_write(header, index, low)
	if is64 do kernel_pci_bar_write(header, index + 1, high)
	if mask == 0 do return 0
	return (~mask) + 1
}

kernel_pci_bar_valid :: proc(bar: pci.Bar) -> bool {
	if bar.addr == 0 || bar.size == 0 do return false
	if bar.size & (bar.size - 1) != 0 do return false
	if bar.addr & (bar.size - 1) != 0 do return false
	return bar.addr + bar.size >= bar.addr
}
kernel_pci_capabilities :: proc(h: ^pci.Header, out: ^[64]pci.Capability) -> (count: u8) {

	ptr := h.capabilitiesPtr
	seen: [256]bool

	for ptr != 0 && count < u8(len(out^)) {
		if ptr < 0x40 || ptr >= 0xFE do break
		if seen[ptr] do break

		seen[ptr] = true

		capHeader := ah.mmio_read_u16(rawptr(uintptr(h) + uintptr(ptr)))

		out[count] = pci.Capability {
			id     = u8(capHeader & 0xFF),
			offset = ptr,
		}
		count += 1
		ptr = u8(capHeader >> 8)

	}
	return count

}
