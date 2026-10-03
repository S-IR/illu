package userschedule


SaveControl :: bit_field u64 {
	restoring: bool | 1,
	reserved:  u64  | 63,
}
#assert(size_of(SaveControl) == size_of(u64))

XSAVE_AREA_BYTES :: 2752
XSAVE_MASK_ALL :: max(u64)
MXCSR_DEFAULT :: u32(0x1F80)
XSAVE_MXCSR_OFFSET :: 24

UserSaveArea :: struct #align (64) {
	rax, rbx, rcx, rdx, rsi, rdi, rbp:    u64,
	r8, r9, r10, r11, r12, r13, r14, r15: u64,
	rip, rsp, rflags:                     u64,
	gsBase:                               u64,
	control:                              SaveControl,
	xsaveMask:                            u64,
	_:                                    [3]u64,
	xsave:                                [XSAVE_AREA_BYTES]u8,
}

#assert(offset_of(UserSaveArea, rax) == 0)
#assert(offset_of(UserSaveArea, r15) == 112)
#assert(offset_of(UserSaveArea, rip) == 120)
#assert(offset_of(UserSaveArea, rsp) == 128)
#assert(offset_of(UserSaveArea, rflags) == 136)
#assert(offset_of(UserSaveArea, gsBase) == 144)
#assert(offset_of(UserSaveArea, control) == 152)
#assert(offset_of(UserSaveArea, xsaveMask) == 160)
#assert(offset_of(UserSaveArea, xsave) == 192)
#assert(offset_of(UserSaveArea, xsave) % 64 == 0)
#assert(XSAVE_AREA_BYTES % 64 == 0)

save_area_init :: proc "contextless" (area: ^UserSaveArea, rip, rsp: u64) {
	area^ = {
		rip       = rip,
		rsp       = rsp,
		rflags    = 0x202,
		control   = {restoring = true},
		xsaveMask = XSAVE_MASK_ALL,
	}
	(^u32)(&area.xsave[XSAVE_MXCSR_OFFSET])^ = MXCSR_DEFAULT
}


SCHED_WEIGHT_TOTAL :: u64(1_000_000)

CPU_INFO_ADDR :: u64(0x7FF0_0000_0000)

MAX_IDLE_STATES :: 7

CpuInfo :: struct #align (64) {
	grantedWeight: u64,
	apicId:         u32,
	mwaitHints:     [MAX_IDLE_STATES]u32,
	idleCount:      u8,
	online:         bool,
}
#assert(size_of(CpuInfo) == 64)

CpuInfoPage :: struct {
	tscTicksPerMs: u64,
	cpuCount:      u32,
	cpus:          [0]CpuInfo,
}
#assert(offset_of(CpuInfoPage, cpus) == size_of(CpuInfo))

cpu_infos :: proc "contextless" (page: ^CpuInfoPage) -> []CpuInfo {
	return ([^]CpuInfo)(&page.cpus)[:page.cpuCount]
}
