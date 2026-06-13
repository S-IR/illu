package kernel
import ah "../asm_helpers"


CPUID_ECX1_Flag :: enum u32 {
	X2APIC = 21,
	// ... many more
}
CPUID_ECX1 :: bit_set[CPUID_ECX1_Flag;u32]
cpuid_has_x2apic :: proc() -> bool {
	r: ah.CPUIDResult
	ah.cpuid_asm(.FEATURE_INFO, 0, &r)
	return .X2APIC in transmute(CPUID_ECX1)r.ecx
}
