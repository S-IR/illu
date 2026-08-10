package ah

CPUIDResult :: struct {
	eax, ebx, ecx, edx: u32,
}
CPUIDLeaf :: enum u32 {
	VENDOR_STRING         = 0x0,
	FEATURE_INFO          = 0x1, // includes x2APIC, SSE, etc.
	MONITOR_MWAIT         = 0x5,
	EXTENDED_FEATURE_INFO = 0x8000_0001,
	// more
}

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		cpuid_asm :: proc(leaf: CPUIDLeaf, subleaf: u32, result: ^CPUIDResult) ---
	}

} else {
	cpuid_asm :: proc(leaf: CPUIDLeaf, subleaf: u32, result: ^CPUIDResult) {
		result.eax = 0
		result.ebx = 0
		result.ecx = 0
		result.edx = 0
	}
}
