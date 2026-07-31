package acpi

import "base:intrinsics"

Rsdp :: struct #packed {
	signature:   [8]u8,
	checksum:    u8,
	oemId:       [6]u8,
	revision:    u8,
	rsdtAddr:    u32,
	length:      u32,
	xsdtAddr:    u64,
	extChecksum: u8,
	reserved:    [3]u8,
}

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

McfgEntry :: struct #packed {
	baseAddr:     u64,
	segmentGroup: u16,
	startBus:     u8,
	endBus:       u8,
	reserved:     u32,
}

find_table :: proc(rsdp: ^Rsdp, sig: [4]u8) -> ^Header {
	if rsdp.revision >= 2 {
		xsdt := (^Header)(uintptr(rsdp.xsdtAddr))
		numEntries := (xsdt.length - u32(size_of(Header))) / 8
		entries := ([^]u64)(intrinsics.ptr_offset((^u8)(rawptr(xsdt)), size_of(Header)))
		for i in 0 ..< numEntries {
			hdr := (^Header)(uintptr(entries[i]))
			if hdr.signature == sig do return hdr
		}
	} else {
		rsdt := (^Header)(uintptr(rsdp.rsdtAddr))
		numEntries := (rsdt.length - u32(size_of(Header))) / 4
		entries := ([^]u32)(intrinsics.ptr_offset((^u8)(rawptr(rsdt)), size_of(Header)))
		for i in 0 ..< numEntries {
			hdr := (^Header)(uintptr(entries[i]))
			if hdr.signature == sig do return hdr
		}
	}
	return nil
}

ecam_base :: proc(rsdp: ^Rsdp) -> u64 {
	hdr := find_table(rsdp, {'M', 'C', 'F', 'G'})
	if hdr == nil do return 0
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

MadtLocalX2Apic :: struct #packed {
	type:     u8,
	length:   u8,
	reserved: u16,
	x2ApicId: u32,
	flags:    u32,
	acpiUid:  u32,
}

collect_ap_ids :: proc(rsdp: ^Rsdp, bspId: u32, out: []u32) -> (count: int = 0) {
	madt := cast(^MadtHeader)find_table(rsdp, {'A', 'P', 'I', 'C'})
	if madt == nil do return 0

	body := uintptr(rawptr(madt)) + size_of(MadtHeader)
	end := uintptr(rawptr(madt)) + uintptr(madt.length)

	PROCESSOR_LOCAL_APIC :: 0
	PROCESSOR_LOCAL_X2APIC :: 9

	for body < end {
		recType := (^u8)(body)^
		recLen := (^u8)(body + 1)^

		switch recType {
		case PROCESSOR_LOCAL_APIC:
			rec := cast(^MadtLocalApic)body
			enabled := (rec.flags & 1) != 0 || (rec.flags & 2) != 0
			id := u32(rec.apicId)
			if enabled && id != bspId {
				if out != nil && count < len(out) {
					out[count] = id
				}
				count += 1
			}
		case PROCESSOR_LOCAL_X2APIC:
			rec := cast(^MadtLocalX2Apic)body
			enabled := (rec.flags & 1) != 0 || (rec.flags & 2) != 0
			id := rec.x2ApicId
			if enabled && id != bspId {
				if out != nil && count < len(out) {
					out[count] = id
				}
				count += 1
			}
		}
		body += uintptr(recLen)
	}
	return count
}
