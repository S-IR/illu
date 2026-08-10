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

@(export, link_name = "kernel_mwait_hint")
mwaitHint: u32

cpuid_init_mwait :: proc() {
	maxLeaf: ah.CPUIDResult
	ah.cpuid_asm(.VENDOR_STRING, 0, &maxLeaf)
	print.kensure(maxLeaf.eax >= u32(ah.CPUIDLeaf.MONITOR_MWAIT),
		"CPU does not expose MONITOR/MWAIT")
	if maxLeaf.eax < u32(ah.CPUIDLeaf.MONITOR_MWAIT) do return

	r: ah.CPUIDResult
	ah.cpuid_asm(.MONITOR_MWAIT, 0, &r)

	deepest: u32 = 0
	for c in u32(0) ..< 8 {
		substates := (r.edx >> (c * 4)) & 0xF
		if substates != 0 do deepest = c
	}

	if deepest == 0 {
		// Some hypervisors expose MWAIT but omit the C-state bitmap. C1 is
		// the safest non-HLT hint in that case.
		deepest = 1
	}
	mwaitHint = deepest << 4
}
