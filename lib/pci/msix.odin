package pci
import "../shared"
import "base:runtime"
import "core:slice"
CAP_ID_MSIX :: u8(0x11)

MsixMessageControl :: bit_field u16 {
	tableSizeMinusOne: u16  | 11,
	reserved:          u16  | 3,
	functionMask:      bool | 1,
	enable:            bool | 1,
}
MSIX_BAR_INDEX_MASK :: u32(0b111)
MSI_ADDRESS_BASE :: u32(0xFEE0_0000)

MsixCapability :: struct #packed {
	id:             u8,
	next:           u8,
	messageControl: MsixMessageControl,
	table:          u32,
	pba:            u32,
}
#assert(size_of(MsixCapability) == 12)
MsixTableEntry :: struct #packed {
	msgAddrLo:     u32,
	msgAddrHi:     u32,
	msgData:       u32,
	vectorControl: u32,
}
#assert(size_of(MsixTableEntry) == 16)

msix_table :: proc "contextless" (
	d: ^Device,
) -> (
	table: []MsixTableEntry,
	capOffset: u8,
	err: shared.Error,
) {
	context = runtime.default_context()
	if !shared.assert(d != nil) do return nil, 0, .InvalidAPICall

	for capability in d.capabilities {
		if capability.id == CAP_ID_MSIX {
			capOffset = capability.offset
			break
		}
	}
	if capOffset == 0 do return nil, 0, .NotFound
	messageControl := transmute(MsixMessageControl)ecam_read_u16(
		d.configBase,
		u64(capOffset) + u64(offset_of(MsixCapability, messageControl)),
	)
	tableRaw := ecam_read_u32(d.configBase, u64(capOffset) + u64(offset_of(MsixCapability, table)))

	count := u64(messageControl.tableSizeMinusOne) + 1
	barIndex := u64(tableRaw & MSIX_BAR_INDEX_MASK)
	offset := u64(tableRaw &~ MSIX_BAR_INDEX_MASK)

	if barIndex >= len(d.bars) do return nil, 0, .Corrupt
	if !d.bars[barIndex].isMemory || d.bars[barIndex].size == 0 do return nil, 0, .Corrupt
	if offset + count * size_of(MsixTableEntry) > d.bars[barIndex].size do return nil, 0, .Corrupt

	entries := (^MsixTableEntry)(uintptr(d.bars[barIndex].addr + offset))
	return slice.from_ptr(entries, int(count)), capOffset, .None

}
