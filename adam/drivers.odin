package adam

import "../lib/pci"

DriverResult :: enum {
	Ignored,
	Initialized,
	Unsupported,
	Failed,
}

adam_dispatch_pci_device :: proc(device: ^pci.Device) -> (result: DriverResult, code: u64) {
	switch device.classCode {
	case .NETWORK:
		switch device.subclass {
		case .WIFI:
			switch device.vendorId {
			case RTL8822BE_VENDOR, RTL8822BE_DEVICE:
				return rtl8822be_probe(device)
			}
		case .ETHERNET:
			// Future: return e1000_probe(device)
			return .Unsupported, 0
		}
	}

	return .Ignored, 0
}
