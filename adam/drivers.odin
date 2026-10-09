package adam

import "../lib/fs"
import "../lib/nvme"
import "../lib/pci"
import "../lib/spinlock"
import "gs"
DriverResult :: enum {
	Ignored,
	Initialized,
	Unsupported,
	Failed,
}

disks: struct {
	v:    [dynamic]fs.Disk,
	lock: spinlock.Spinlock,
}
PciDeviceError :: union {
	nvme.InitError,
}
adam_dispatch_pci_device :: proc(
	device: ^pci.Device,
) -> (
	result: DriverResult = .Failed,
	code: PciDeviceError,
) {
	switch device.classCode {
	case .MASS_STORAGE:
		if device.subclass == .NVM && device.progIf == pci.PROG_IF_NVME {
			nvmeDevice, blockCount := nvme.init(device) or_return

			if disks.v == nil do disks.v = make([dynamic]fs.Disk)
			disk, used := fs.disk_new(
				nvmeDevice,
				auto_cast nvmeDevice.lbaSize,
				blockCount,
				gs.nextMadeUpAddr.v,
			)
			if used == -1 do return .Failed, .BlockSizeUnsupported
			{
				spinlock.lock(&gs.nextMadeUpAddr.lock)
				defer spinlock.unlock(&gs.nextMadeUpAddr.lock)
				gs.nextMadeUpAddr.v += u64(used)
			}
			{
				spinlock.lock(&disks.lock)
				defer spinlock.unlock(&disks.lock)
				if _, err := append(&disks.v, disk); err != nil do return .Failed, .OutOfMemory
			}

			// append(&disks,
			return .Initialized, {}
		}
	case .NETWORK:
		#partial switch device.subclass {
		case .WIFI:
			return
		// if device.vendorId == RTL8822BE_VENDOR && device.deviceId == RTL8822BE_DEVICE {
		// 	return rtl8822be_init(device)
		// }
		case .ETHERNET:
			// Future: return e1000_probe(device)
			return .Unsupported, {}
		}
	}

	return .Ignored, {}
}
