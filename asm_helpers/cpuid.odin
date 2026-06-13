package ah

CPUIDResult :: struct {
	eax, ebx, ecx, edx: u32,
}
CPUIDLeaf :: enum u32 {
	VENDOR_STRING = 0x0,
	FEATURE_INFO  = 0x1, // includes x2APIC, SSE, etc.
	// more
}

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		cpuid_asm :: proc(leaf: CPUIDLeaf, subleaf: u32, result: ^CPUIDResult) ---
	}

}
