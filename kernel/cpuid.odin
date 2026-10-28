package kernel
import ah "../asm_helpers"
import "../lib/userschedule"
import "print"

CPUIDECX1Flag :: enum u32 {
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
TEST_NO_MELTDOWN :: #config(TEST_NO_MELTDOWN, false)
#assert(!TEST_NO_MELTDOWN || ODIN_DEBUG)

cpuid_meltdown_vulnerable :: proc() -> bool {
	when TEST_NO_MELTDOWN do return false
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
RTM_CPUID_BIT :: u32(11)
IA32_SPEC_CTRL_MSR :: u32(0x48)
SSBD_SPEC_CTRL_BIT :: u64(2)

ArchCapability :: enum u64 {
	RDCL_NO      = 0,
	MDS_NO       = 5,
	TAA_NO       = 8,
	SBDR_SSDP_NO = 13,
	FBSDP_NO     = 14,
	PSDP_NO      = 15,
	RFDS_NO      = 27,
	RFDS_CLEAR   = 28,
}
ArchCapabilities :: bit_set[ArchCapability;u64]

@(export, link_name = "kernel_cpu_needs_verw")
cpuNeedsVerw: bool
cpuHasSSBD: bool

cpuid_init_speculation_mitigations :: proc() {
	vendor: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &vendor)
	if vendor.eax < u32(ah.CPUIDLeaf.STRUCTURED_EXTENDED_FEATURES) do return

	extFeatures: ah.CPUIDResult
	ah.cpuid_asm(.STRUCTURED_EXTENDED_FEATURES, 0, &extFeatures)
	cpuHasSSBD = (extFeatures.edx >> SSBD_CPUID_BIT) & 1 == 1

	hasMdClear := (extFeatures.edx >> MD_CLEAR_CPUID_BIT) & 1 == 1
	if !hasMdClear do return
	cpuNeedsVerw = true

	hasArchCapabilities := (extFeatures.edx >> ARCH_CAPABILITIES_CPUID_BIT) & 1 == 1
	if !hasArchCapabilities do return
	caps := transmute(ArchCapabilities)ah.rdmsr_asm(IA32_ARCH_CAPABILITIES_MSR)
	hasRTM := (extFeatures.ebx >> RTM_CPUID_BIT) & 1 == 1

	mdsSafe := .MDS_NO in caps
	taaSafe := !hasRTM || .TAA_NO in caps
	mmioStaleSafe := ArchCapabilities{.SBDR_SSDP_NO, .FBSDP_NO, .PSDP_NO} <= caps
	rfdsSafe := .RFDS_NO in caps || .RFDS_CLEAR not_in caps
	cpuNeedsVerw = !(mdsSafe && taaSafe && mmioStaleSafe && rfdsSafe)
}

cpu_enable_ssbd :: proc "contextless" () {
	if !cpuHasSSBD do return
	ah.wrmsr_asm(
		IA32_SPEC_CTRL_MSR,
		ah.rdmsr_asm(IA32_SPEC_CTRL_MSR) | (u64(1) << SSBD_SPEC_CTRL_BIT),
	)
}

cpuHasPCID: bool

cpuid_init_pcid :: proc() {
	r: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &r)
	cpuHasPCID = (r.ecx >> 17) & 1 == 1
}


CR4_PCIDE_BIT :: u64(1) << 17

cpuid_enable_pcid :: proc "contextless" () {
	if !cpuHasPCID do return
	print.kassert(ah.read_cr3() & 0xFFF == 0, "cpuid_enable_pcid: CR3 already has a PCID tag")
	ah.write_cr4(ah.read_cr4() | CR4_PCIDE_BIT)
}

CR4_FSGSBASE_BIT :: u64(1) << 16

cpuid_has_fsgsbase :: proc() -> bool {
	FSGSBASE_CPUID_BIT :: 0
	vendor: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &vendor)
	if vendor.eax < u32(ah.CPUIDLeaf.STRUCTURED_EXTENDED_FEATURES) do return false
	r: ah.CPUIDResult
	ah.cpuid_asm(.STRUCTURED_EXTENDED_FEATURES, 0, &r)
	return (r.ebx >> FSGSBASE_CPUID_BIT) & 1 == 1
}

cpuid_enable_fsgsbase :: proc "contextless" () {
	ah.write_cr4(ah.read_cr4() | CR4_FSGSBASE_BIT)
}

CR0_NE :: u64(1) << 5
CR0_WP :: u64(1) << 16
CR4_PGE_BIT :: u64(1) << 7
CR4_SMEP_BIT :: u64(1) << 20
CR4_SMAP_BIT :: u64(1) << 21

@(export, link_name = "kernel_cpu_has_smap")
cpuHasSMAP: bool

cpuid_structured_ebx_bit :: proc "contextless" (bit: u32) -> bool {
	vendor: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &vendor)
	if vendor.eax < u32(ah.CPUIDLeaf.STRUCTURED_EXTENDED_FEATURES) do return false
	r: ah.CPUIDResult
	ah.cpuid_asm(.STRUCTURED_EXTENDED_FEATURES, 0, &r)
	return (r.ebx >> bit) & 1 == 1
}

cpu_enable_kernel_protections :: proc "contextless" () {
	SMEP_CPUID_BIT :: 7
	SMAP_CPUID_BIT :: 20
	ah.write_cr0(ah.read_cr0() | CR0_WP | CR0_NE)
	cr4 := ah.read_cr4() | CR4_PGE_BIT
	if cpuid_structured_ebx_bit(SMEP_CPUID_BIT) do cr4 |= CR4_SMEP_BIT
	cpuHasSMAP = cpuid_structured_ebx_bit(SMAP_CPUID_BIT)
	if cpuHasSMAP do cr4 |= CR4_SMAP_BIT
	ah.write_cr4(cr4)
}

XSTATE_X87 :: u64(1) << 0
XSTATE_SSE :: u64(1) << 1
XSTATE_AVX :: u64(1) << 2
XSTATE_AVX512 :: u64(0b111) << 5
CR4_OSXSAVE_BIT :: u64(1) << 18

@(export, link_name = "kernel_xsave_mask")
xsaveMask: u64
@(export, link_name = "kernel_has_xsavec")
cpuHasXsavec: bool

cpuid_init_xsave :: proc() {
	XSAVE_CPUID_BIT :: 26
	AVX_CPUID_BIT :: 28
	AVX512F_CPUID_BIT :: 16
	XSAVEC_CPUID_BIT :: 1

	features: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &features)
	print.kensure(
		(features.ecx >> XSAVE_CPUID_BIT) & 1 == 1,
		"cpuid_init_xsave: xsave unsupported",
	)

	supportedRaw: ah.CPUIDResult
	ah.cpuid_asm(.XSAVE_STATE, 0, &supportedRaw)
	supported := u64(supportedRaw.eax) | u64(supportedRaw.edx) << 32

	xsaveMask = XSTATE_X87 | XSTATE_SSE
	hasAVX := (features.ecx >> AVX_CPUID_BIT) & 1 == 1 && supported & XSTATE_AVX != 0
	if hasAVX do xsaveMask |= XSTATE_AVX
	if hasAVX &&
	   supported & XSTATE_AVX512 == XSTATE_AVX512 &&
	   cpuid_structured_ebx_bit(AVX512F_CPUID_BIT) {
		xsaveMask |= XSTATE_AVX512
	}

	subleaf1: ah.CPUIDResult
	ah.cpuid_asm(.XSAVE_STATE, 1, &subleaf1)
	cpuHasXsavec = (subleaf1.eax >> XSAVEC_CPUID_BIT) & 1 == 1
}

cpu_enable_xsave :: proc() {
	print.kassert(xsaveMask & (XSTATE_X87 | XSTATE_SSE) == XSTATE_X87 | XSTATE_SSE)
	ah.write_cr4(ah.read_cr4() | CR4_OSXSAVE_BIT)
	ah.xsetbv_asm(0, xsaveMask)
	sizes: ah.CPUIDResult
	ah.cpuid_asm(.XSAVE_STATE, 0, &sizes)
	print.kensure(
		u64(sizes.ebx) <= userschedule.XSAVE_AREA_BYTES,
		"cpu_enable_xsave: xsave area larger than the save area",
	)
}

cpuid_has_1gb_pages :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.EXTENDED_FEATURE_INFO, 0, &r)
	return (r.edx >> 26) & 1 == 1
}

cpuid_has_rdtscp :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.EXTENDED_FEATURE_INFO, 0, &r)
	return (r.edx >> 27) & 1 == 1
}

cpuid_has_invariant_tsc :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.EXTENDED_MAX, 0, &r)
	if r.eax < u32(ah.CPUIDLeaf.ADVANCED_POWER_MANAGEMENT) do return false
	ah.cpuid_asm(.ADVANCED_POWER_MANAGEMENT, 0, &r)
	return (r.edx >> 8) & 1 == 1
}
