package kernel
import ah "../asm_helpers"
import "print"

CPUIDECX1Flag :: enum u32 {
	SSE3         = 0,
	X2APIC       = 21,
	TSC_DEADLINE = 24,
	// ... many more
}
CPUID_ECX1 :: bit_set[CPUIDECX1Flag;u32]

cpuid_has_x2apic :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &r)
	return .X2APIC in transmute(CPUID_ECX1)r.ecx
}
cpuid_has_tsc_deadline :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &r)
	return .TSC_DEADLINE in transmute(CPUID_ECX1)r.ecx
}
cpuid_has_sse3 :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &r)
	return .SSE3 in transmute(CPUID_ECX1)r.ecx
}

cpuid_has_1gb_pages :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.EXTENDED_FEATURE_INFO, 0, &r)
	return (r.edx >> 26) & 1 == 1
}

IA32_ARCH_CAPABILITIES_MSR :: u32(0x10A)
ARCH_CAPABILITIES_CPUID_BIT :: u32(29)
RDCL_NO_BIT :: u64(0)

cpuMeltdownVulnerable: bool

cpuid_init_meltdown_check :: proc() {
	cpuMeltdownVulnerable = cpuid_meltdown_vulnerable()
}

// Meltdown/RDCL is a silicon bug, mostly Intel, roughly 1995-2018 designs.
// AMD was never affected by the classic variant. Newer CPUs report their own
// immunity via IA32_ARCH_CAPABILITIES; anything that doesn't report that at
// all predates the mechanism and is treated as vulnerable -- fail closed,
// never assume safety we can't prove.
cpuid_meltdown_vulnerable :: proc() -> bool {
	vendor: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &vendor)

	isAMD := vendor.ebx == 0x6874_7541 && vendor.edx == 0x6974_6e65 && vendor.ecx == 0x444d_4163
	if isAMD do return false

	if vendor.eax < u32(ah.CPUIDLeaf.STRUCTURED_EXTENDED_FEATURES) do return true

	extFeatures: ah.CPUIDResult
	ah.cpuid_asm(.STRUCTURED_EXTENDED_FEATURES, 0, &extFeatures)
	hasArchCapabilities := (extFeatures.edx >> ARCH_CAPABILITIES_CPUID_BIT) & 1 == 1
	if !hasArchCapabilities do return true

	archCaps := ah.rdmsr_asm(IA32_ARCH_CAPABILITIES_MSR)
	rdclNo := (archCaps >> RDCL_NO_BIT) & 1 == 1
	return !rdclNo
}

MD_CLEAR_CPUID_BIT :: u32(10)
SSBD_CPUID_BIT :: u32(31)
IA32_SPEC_CTRL_MSR :: u32(0x48)
SSBD_SPEC_CTRL_BIT :: u64(2)

@(export, link_name = "kernel_cpu_has_md_clear")
cpuHasMdClear: bool

cpuid_init_speculation_mitigations :: proc() {
	vendor: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &vendor)
	if vendor.eax < u32(ah.CPUIDLeaf.STRUCTURED_EXTENDED_FEATURES) do return

	extFeatures: ah.CPUIDResult
	ah.cpuid_asm(.STRUCTURED_EXTENDED_FEATURES, 0, &extFeatures)

	cpuHasMdClear = (extFeatures.edx >> MD_CLEAR_CPUID_BIT) & 1 == 1

	hasSSBD := (extFeatures.edx >> SSBD_CPUID_BIT) & 1 == 1
	if hasSSBD {
		current := ah.rdmsr_asm(IA32_SPEC_CTRL_MSR)
		ah.wrmsr_asm(IA32_SPEC_CTRL_MSR, current | (u64(1) << SSBD_SPEC_CTRL_BIT))
	}
}

INVPCID_CPUID_BIT :: u32(10)
cpuHasPCID: bool
cpuHasInvpcid: bool

cpuid_init_pcid :: proc() {
	r: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &r)
	cpuHasPCID = (r.ecx >> 17) & 1 == 1
	if !cpuHasPCID do return

	vendor: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &vendor)
	if vendor.eax < u32(ah.CPUIDLeaf.STRUCTURED_EXTENDED_FEATURES) do return

	extFeatures: ah.CPUIDResult
	ah.cpuid_asm(.STRUCTURED_EXTENDED_FEATURES, 0, &extFeatures)
	cpuHasInvpcid = (extFeatures.ebx >> INVPCID_CPUID_BIT) & 1 == 1
}


CR4_PCIDE_BIT :: u64(1) << 17

cpuid_enable_pcid :: proc "contextless" () {
	if !cpuHasPCID do return
	print.kassert(ah.read_cr3() & 0xFFF == 0, "cpuid_enable_pcid: CR3 already has a PCID tag")
	ah.write_cr4(ah.read_cr4() | CR4_PCIDE_BIT)
}
