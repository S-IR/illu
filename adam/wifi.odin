package adam

import "../lib/pci"
import "../lib/spinlock"
import ah "../asm_helpers"

import "base:runtime"
import "core:mem"


RTL8822BE_State :: struct #all_or_none {
	bar: pci.Bar,
	mmio: u64,
	txDma: rawptr,
	txDmaPhys: u64,
	txSlotSize: u32,
	txSlots: u16,
	txHead:           u16,
	txLock:           spinlock.Spinlock,
	rxDma: rawptr,
	rxDmaPhys: u64,
	rxSlotSize: u32,
	rxSlots: u16,
	rxHead:           u16,
	rxTail:           u16,
	rxLock:           spinlock.Spinlock,
}

WifiDma :: struct {
	tx: rawptr,
	txPhys: u64,
	rx: rawptr,
	rxPhys: u64,
}

TX_SLOTS :: 2
TX_SLOT_SIZE :: 2048
RX_SLOTS :: 2
RX_SLOT_SIZE :: 12288

WifiImpl :: union {
	RTL8822BE_State,
}

WifiDevice :: struct #all_or_none {
	bar:  pci.Bar,
	impl: WifiImpl,
}

networkRegistry := struct {
	wifis: [dynamic]WifiDevice,
	lock:  spinlock.Spinlock,
}{}
wifi_register :: proc(device: WifiDevice) -> (err: runtime.Allocator_Error) {
	spinlock.lock(&networkRegistry.lock)
	defer spinlock.unlock(&networkRegistry.lock)

	if networkRegistry.wifis == nil {
		networkRegistry.wifis, err = make([dynamic]WifiDevice, 0, 1)
		if err != nil do return err
	}

	_, err = append(&networkRegistry.wifis, device)
	return err
}

WifiError :: enum {
	None,
	InvalidDevice,
	InvalidFrame,
	NotReady,
	NoPacket,
	Busy,
}

wifi_configure_io :: proc(device: ^WifiDevice, dma: WifiDma) -> bool {
	if device == nil || dma.tx == nil || dma.rx == nil do return false
	switch &v in device.impl {
	case RTL8822BE_State:
		base := uintptr(v.mmio)
		for i in 0 ..< RX_SLOTS {
			desc := rawptr(uintptr(dma.rx) + uintptr(i * 8))
			bufferPhys := dma.rxPhys + u64(RX_SLOTS * 8) + u64(i * RX_SLOT_SIZE)
			(^u16)(desc)^ = RX_SLOT_SIZE
			(^u16)(rawptr(uintptr(desc) + 2))^ = 0
			(^u32)(rawptr(uintptr(desc) + 4))^ = u32(bufferPhys)
		}
		ah.mmio_write_u32(rawptr(base + 0x328), u32(uintptr(dma.tx)))
		ah.mmio_write_u16(rawptr(base + 0x388), TX_SLOTS)
		ah.mmio_write_u32(rawptr(base + 0x39C), 0xFFFF_FFFF)
		ah.mmio_write_u16(rawptr(base + 0x3A8), 0)
		ah.mmio_write_u32(rawptr(base + 0x338), u32(uintptr(dma.rx)))
		ah.mmio_write_u16(rawptr(base + 0x382), RX_SLOTS)
		ah.mmio_write_u16(rawptr(base + 0x3B4), 0)
		v.txDma, v.txDmaPhys = dma.tx, dma.txPhys
		v.txSlotSize, v.txSlots, v.txHead = TX_SLOT_SIZE, TX_SLOTS, 0
		v.rxDma, v.rxDmaPhys = dma.rx, dma.rxPhys
		v.rxSlotSize, v.rxSlots, v.rxTail = RX_SLOT_SIZE, RX_SLOTS, 0
		return true
	}
	return false
}

rtl8822be_send :: proc(state: ^RTL8822BE_State, frame: []u8) -> WifiError {
	if state == nil || state.txDma == nil || state.txSlots < 2 || state.txSlotSize < 2048 {
		return .NotReady
	}
	if u32(len(frame)) + 48 > state.txSlotSize do return .InvalidFrame

	spinlock.lock(&state.txLock)
	defer spinlock.unlock(&state.txLock)

	nextHead := (state.txHead + 1) % state.txSlots
	slot := uintptr(state.txHead)
	bufferDesc := rawptr(uintptr(state.txDma) + slot * 16)
	packet := uintptr(state.txDma) + uintptr(state.txSlots * 16) + slot * uintptr(state.txSlotSize)
	packetPhys := state.txDmaPhys + u64(state.txSlots * 16) + u64(slot * uintptr(state.txSlotSize))
	mem.zero(rawptr(packet), 48)
	mem.copy(rawptr(packet + 48), rawptr(&frame[0]), len(frame))
	(^u32)(rawptr(packet))^ = u32(len(frame)) | u32(48 << 16) | u32(1 << 26) | u32(1 << 31)
	(^u32)(bufferDesc)^ = u32(48)
	(^u16)(rawptr(uintptr(bufferDesc) + 2))^ = u16((48 + len(frame) + 127) / 128)
	(^u32)(rawptr(uintptr(bufferDesc) + 4))^ = u32(packetPhys)
	(^u16)(rawptr(uintptr(bufferDesc) + 8))^ = u16(len(frame))
	(^u16)(rawptr(uintptr(bufferDesc) + 10))^ = 0
	(^u32)(rawptr(uintptr(bufferDesc) + 12))^ = u32(packetPhys + 48)
	state.txHead = nextHead
	ah.mmio_write_u16(rawptr(uintptr(state.mmio) + 0x3A8), state.txHead)
	return .None
}

rtl8822be_poll :: proc(state: ^RTL8822BE_State, buffer: []u8) -> (WifiError, int) {
	if state == nil || state.rxDma == nil || state.rxSlots < 2 || state.rxSlotSize == 0 {
		return .NotReady, 0
	}
	if len(buffer) == 0 do return .InvalidFrame, 0

	spinlock.lock(&state.rxLock)
	defer spinlock.unlock(&state.rxLock)

	hardwareHead := u16((ah.mmio_read_u32(rawptr(uintptr(state.mmio) + 0x3B4)) >> 16) & 0x0FFF)
	if state.rxTail == hardwareHead % state.rxSlots do return .NoPacket, 0
	slot := uintptr(state.rxTail)
	desc := rawptr(uintptr(state.rxDma) + slot * 8)
	count := min(u32(len(buffer)), u32((^u16)(rawptr(uintptr(desc) + 2))^))
	source := rawptr(uintptr(state.rxDma) + uintptr(state.rxSlots * 8) + slot * uintptr(state.rxSlotSize))
	mem.copy(rawptr(&buffer[0]), source, int(count))
	(^u16)(rawptr(uintptr(desc) + 2))^ = 0
	state.rxTail = (state.rxTail + 1) % state.rxSlots
	ah.mmio_write_u16(rawptr(uintptr(state.mmio) + 0x3B4), state.rxTail)
	return .None, int(count)
}

wifi_send :: proc(device: ^WifiDevice, frame: []u8) -> WifiError {
	if device == nil do return .InvalidDevice
	if len(frame) == 0 do return .InvalidFrame

	switch &v in device.impl {
	case RTL8822BE_State:
		return rtl8822be_send(&v, frame)
	}

	return .InvalidDevice
}

wifi_poll :: proc(device: ^WifiDevice, buffer: []u8) -> (WifiError, int) {
	if device == nil do return .InvalidDevice, 0
	if len(buffer) == 0 do return .InvalidFrame, 0

	switch &v in device.impl {
	case RTL8822BE_State:
		return rtl8822be_poll(&v, buffer)
	}


	return .InvalidDevice, 0
}
