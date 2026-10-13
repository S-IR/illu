package adam

import "../lib/fs"
import "../lib/nvme"
import "../lib/pci"
import "../lib/shared"
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
adam_dispatch_pci_device :: proc(
	device: ^pci.Device,
) -> (
	result: DriverResult = .Failed,
	code: shared.Error,
) {
	switch device.classCode {
	case .MASS_STORAGE:
		if device.subclass == .NVM && device.progIf == pci.PROG_IF_NVME {
			nvmeDisk: fs.NvmeDisk
			blockCount: u64
			nvmeDisk.dev, blockCount = nvme.init(device) or_return
			info := nvme.queue_pair_create(&nvmeDisk.dev) or_return
			nvmeDisk.queue = nvme.queue_init(info) or_return
			defer if result != nil do nvme.controller_disable(nvmeDisk.dev.regs, nvmeDisk.dev.cap)

			disk: fs.Disk
			{
				spinlock.lock(&gs.nextMadeUpAddr.lock)
				defer spinlock.unlock(&gs.nextMadeUpAddr.lock)
				used: int
				disk, used = fs.disk_new(
					nvmeDisk,
					nvmeDisk.dev.lbaSize,
					blockCount,
					gs.nextMadeUpAddr.v,
				)
				if used == -1 do return .Failed, .NvmeBlockSizeUnsupported

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
