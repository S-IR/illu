package adam

import "../lib/pci"
import "../lib/syscalls"

RTL8822BE_VENDOR :: u16(0x10EC)
RTL8822BE_DEVICE :: u16(0xB822)

RTL8822BE_State :: struct {
	mmioHandle: u64,
	vector:     u8,
}

rtl8822be_probe :: proc(device: ^pci.Device) -> (DriverResult, u64) {
	if device.vendorId != RTL8822BE_VENDOR || device.deviceId != RTL8822BE_DEVICE {
		return .Ignored, 0
	}

	pciAddress :=
		u64(device.segment) |
		(u64(device.bus) << 16) |
		(u64(device.device) << 24) |
		(u64(device.function) << 32)

	configPage := device.configBase & ~u64(0xFFF)
	vectorErr, vector, lapicID :=
		syscalls.syscall_interrupt_vector_get_userspace(configPage)
	if vectorErr != .None do return .Failed, 11 + u64(vectorErr)

	command := pci.config_read_u16(device, pci.CONFIG_COMMAND_OFFSET)
	command |= pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER
	pci.config_write_u16(device, pci.CONFIG_COMMAND_OFFSET, command)

	msiOffset, hasMsi := pci.find_capability(device, pci.CAPABILITY_MSI)
	if !hasMsi do return .Failed, 100

	msiControl := pci.config_read_u16(device, uintptr(msiOffset) + pci.MSI_CONTROL)
	is64Bit := msiControl & pci.MSI_CONTROL_64BIT != 0

	pci.config_write_u32(
		device,
		uintptr(msiOffset) + pci.MSI_MESSAGE_ADDR,
		0xFEE0_0000 | (lapicID << 12),
	)

	dataOffset := pci.MSI_MESSAGE_DATA32
	if is64Bit {
		pci.config_write_u32(device, uintptr(msiOffset) + uintptr(0x08), 0)
		dataOffset = pci.MSI_MESSAGE_DATA64
	}

	pci.config_write_u16(device, uintptr(msiOffset) + dataOffset, u16(vector))

	msiControl |= pci.MSI_CONTROL_ENABLE
	pci.config_write_u16(device, uintptr(msiOffset) + pci.MSI_CONTROL, msiControl)

	mmioBar: pci.Bar
	foundMMIO := false
	for bar in device.bars {
		if !bar.isMemory || bar.addr == 0 || bar.size == 0 do continue
		mmioBar = bar
		foundMMIO = true
		break
	}
	if !foundMMIO do return .Failed, 110
	if mmioBar.addr & 3 != 0 do return .Failed, 113

	mmioErr, mmioHandle :=
		syscalls.syscall_multiplexed_memory_create_userspace(mmioBar.addr, mmioBar.size)
	if mmioErr != .None do return .Failed, 114 + u64(mmioErr)

	// Read-only MMIO smoke test through a caller-owned stack buffer.
	value: u32
	readErr := syscalls.syscall_multiplexed_memory_read_userspace(
		mmioHandle,
		0,
		rawptr(&value),
		size_of(u32),
		4,
	)
	if readErr != .None do return .Failed, 121 + u64(readErr)

	state, stateErr := new(RTL8822BE_State)
	if stateErr != nil do return .Failed, 130
	state^ = {
		mmioHandle = mmioHandle,
		vector     = vector,
	}

	registered := wifi_register(WifiDevice {
		pciAddress = pciAddress,
		bar        = mmioBar,
		vector     = vector,
		impl       = state,
	})
	if !registered do return .Failed, 122

	return .Initialized, 0
}
