package adam

import "../lib/pci"

Wifi_Impl :: union {
	^RTL8822BE_State,
}

WifiDevice :: struct #all_or_none {
	pciAddress: u64,
	bar:        pci.Bar,
	vector:     u8,
	impl:       Wifi_Impl,
}

NetworkRegistry :: struct {
	wifis: [dynamic]WifiDevice,
}

networkRegistry: NetworkRegistry

wifi_register :: proc(device: WifiDevice) -> bool {
	_, err := append(&networkRegistry.wifis, device)
	return err == nil
}

wifi_count :: proc() -> int {
	return len(networkRegistry.wifis)
}
