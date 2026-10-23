package adam
import "../lib/diskhelpers"
import "../lib/log"
import "../lib/nvme"
import "../lib/pci"
import "../lib/shared"
import "../lib/spinlock"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "gs"
DriverResult :: enum {
	Ignored,
	Initialized,
	Unsupported,
	Failed,
}

disks: struct {
	v:    [dynamic]diskhelpers.Disk,
	lock: spinlock.Spinlock,
}
ADAM_LOG_RECORDS :: 1024
adamLogRecords: [ADAM_LOG_RECORDS]log.Record
adamLog: log.Ring
adamLogPrinted: u64
NVME_VECTOR :: u32(32)
NVME_MSIX_ROW :: u16(0)

adam_dispatch_pci_device :: proc(
	device: ^pci.Device,
) -> (
	result: DriverResult = .Failed,
	code: shared.Error,
) {
	switch device.classCode {
	case .MASS_STORAGE:
		if device.subclass == .NVM && device.progIf == pci.PROG_IF_NVME {


			nvmeDisk: diskhelpers.NvmeDisk
			blockCount: u64
			nvmeDisk.dev, blockCount = nvme.init(device) or_return
			defer if result != .Initialized do nvme.controller_disable(nvmeDisk.dev.regs, nvmeDisk.dev.cap)

			table, capOffset := pci.msix_table(device) or_return
			cpus := userschedule.cpu_infos(
				(^userschedule.CpuInfoPage)(uintptr(userschedule.CPU_INFO_ADDR)),
			)
			apicId := cpus[syscalls.cpu_current_index()].apicId
			assert(apicId <= 255)
			row := &table[NVME_MSIX_ROW]
			intrinsics.volatile_store(&row.msgAddrLo, pci.MSI_ADDRESS_BASE | apicId << 12)
			intrinsics.volatile_store(&row.msgAddrHi, 0)
			intrinsics.volatile_store(&row.msgData, NVME_VECTOR)
			intrinsics.volatile_store(&row.vectorControl, 0)

			messageControlOffset :=
				uintptr(capOffset) + offset_of(pci.MsixCapability, messageControl)
			messageControl := transmute(pci.MsixMessageControl)pci.config_read_u16(
				device,
				messageControlOffset,
			)
			messageControl.enable = true
			messageControl.functionMask = false
			pci.config_write_u16(device, messageControlOffset, transmute(u16)messageControl)

			command := pci.config_read_u16(device, pci.CONFIG_COMMAND_OFFSET)
			pci.config_write_u16(
				device,
				pci.CONFIG_COMMAND_OFFSET,
				command | pci.COMMAND_INTX_DISABLE,
			)

			info := nvme.queue_pair_create(&nvmeDisk.dev, NVME_MSIX_ROW) or_return
			nvmeDisk.queue = nvme.queue_init(info) or_return

			disk: diskhelpers.Disk
			{
				spinlock.lock(&gs.nextMadeUpAddr.lock)
				defer spinlock.unlock(&gs.nextMadeUpAddr.lock)
				used: int
				disk, used = diskhelpers.disk_new(
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
