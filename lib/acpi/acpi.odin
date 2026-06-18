package acpi

import "base:intrinsics"

Rsdp :: struct #packed {
	signature:   [8]u8,
	checksum:    u8,
	oemId:       [6]u8,
	revision:    u8,
	rsdtAddr:    u32,
	// ACPI 2.0+ fields
	length:      u32,
	xsdtAddr:    u64, // physical address of XSDT — use this, not rsdtAddr
	extChecksum: u8,
	reserved:    [3]u8,
}

// Every ACPI table starts with this 36-byte header
Header :: struct #packed {
	signature:       [4]u8,
	length:          u32,
	revision:        u8,
	checksum:        u8,
	oemId:           [6]u8,
	oemTableId:      [8]u8,
	oemRevision:     u32,
	creatorId:       [4]u8,
	creatorRevision: u32,
}

// One entry in the MCFG table — one per PCI segment group
McfgEntry :: struct #packed {
	baseAddr:     u64,
	segmentGroup: u16,
	startBus:     u8,
	endBus:       u8,
	reserved:     u32,
}

// Walk the XSDT and return the first table matching sig, or nil
find_table :: proc(rsdp: ^Rsdp, sig: [4]u8) -> ^Header {
	xsdt := (^Header)(uintptr(rsdp.xsdtAddr))
	numEntries := (xsdt.length - u32(size_of(Header))) / 8
	// entries[] starts immediately after the XSDT header
	entries := ([^]u64)(intrinsics.ptr_offset((^u8)(rawptr(xsdt)), size_of(Header)))
	for i in 0 ..< numEntries {
		hdr := (^Header)(uintptr(entries[i]))
		if hdr.signature == sig do return hdr
	}
	return nil
}

// Return the ECAM base address for segment group 0 from the MCFG table
ecam_base :: proc(rsdp: ^Rsdp) -> u64 {
	hdr := find_table(rsdp, {'M', 'C', 'F', 'G'})
	if hdr == nil do return 0
	// MCFG body: 8 bytes reserved, then McfgEntry array
	entry := (^McfgEntry)(
		intrinsics.ptr_offset(intrinsics.ptr_offset((^u8)(rawptr(hdr)), size_of(Header)), 8),
	)
	return entry.baseAddr
}


MadtHeader :: struct #packed {
	using hdr:     Header,
	localApicAddr: u32,
	flags:         u32,
}

MadtLocalApic :: struct #packed {
	type:            u8,
	length:          u8,
	acpiProcessorId: u8,
	apicId:          u8,
	flags:           u32,
}
collect_ap_ids :: proc(rsdp: ^Rsdp, bspId: u8, out: []u8) -> (count: int = 0) {
	madt := cast(^MadtHeader)find_table(rsdp, {'A', 'P', 'I', 'C'})
	if madt == nil do return 0


	body := uintptr(rawptr(madt)) + size_of(MadtHeader)
	end := uintptr(rawptr(madt)) + uintptr(madt.length)

	for body < end {
		recType := (^u8)(body)^
		recLen := (^u8)(body + 1)^
		PROCESSOR_LOCAL_APIC :: 0
		if recType == PROCESSOR_LOCAL_APIC {
			rec := cast(^MadtLocalApic)body
			enabled := (rec.flags & 1) != 0 || (rec.flags & 2) != 0
			if enabled && rec.apicId != bspId {
				if out != nil && count < len(out) {
					out[count] = rec.apicId
				}
				count += 1
			}
		}
		body += uintptr(recLen)
	}
	return count
}
