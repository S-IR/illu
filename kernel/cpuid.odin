package kernel
import ah "../asm_helpers"


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
