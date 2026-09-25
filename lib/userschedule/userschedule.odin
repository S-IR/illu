package userschedule


SaveControl :: bit_field u64 {
	restoring: bool | 1,
	reserved:  u64  | 63,
}
#assert(size_of(SaveControl) == size_of(u64))

UserSaveArea :: struct #align (64) {
	fx:                                   [512]u8,
	rax, rbx, rcx, rdx, rsi, rdi, rbp:    u64,
	r8, r9, r10, r11, r12, r13, r14, r15: u64,
	rip, rsp, rflags:                     u64,
	gsBase:                               u64,
	control:                              SaveControl,
}


#assert(offset_of(UserSaveArea, fx) == 0)
#assert(offset_of(UserSaveArea, rax) == 512)
#assert(offset_of(UserSaveArea, rbx) == 520)
#assert(offset_of(UserSaveArea, rcx) == 528)
#assert(offset_of(UserSaveArea, rdx) == 536)
#assert(offset_of(UserSaveArea, rsi) == 544)
#assert(offset_of(UserSaveArea, rdi) == 552)
#assert(offset_of(UserSaveArea, rbp) == 560)
#assert(offset_of(UserSaveArea, r8) == 568)
#assert(offset_of(UserSaveArea, r9) == 576)
#assert(offset_of(UserSaveArea, r10) == 584)
#assert(offset_of(UserSaveArea, r11) == 592)
#assert(offset_of(UserSaveArea, r12) == 600)
#assert(offset_of(UserSaveArea, r13) == 608)
#assert(offset_of(UserSaveArea, r14) == 616)
#assert(offset_of(UserSaveArea, r15) == 624)
#assert(offset_of(UserSaveArea, rip) == 632)
#assert(offset_of(UserSaveArea, rsp) == 640)
#assert(offset_of(UserSaveArea, rflags) == 648)
#assert(offset_of(UserSaveArea, gsBase) == 656)
#assert(offset_of(UserSaveArea, control) == 664)

FX_FCW_DEFAULT :: u16(0x037F)
MXCSR_DEFAULT :: u32(0x1F80)
FX_MXCSR_OFFSET :: 24

save_area_init :: proc "contextless" (area: ^UserSaveArea, rip, rsp: u64) {
	area^ = {
		rip     = rip,
		rsp     = rsp,
		rflags  = 0x202,
		control = {restoring = true},
	}
	(^u16)(&area.fx[0])^ = FX_FCW_DEFAULT
	(^u32)(&area.fx[FX_MXCSR_OFFSET])^ = MXCSR_DEFAULT
}


SCHED_WEIGHT_TOTAL :: u64(1_000_000)
SAVE_AREA_FX_RESERVED :: 464

CPU_INFO_ADDR :: u64(0x7FF0_0000_0000)

MAX_IDLE_STATES :: 7

CpuInfo :: struct #align (64) {
	runnableWeight: u64,
	apicId:         u32,
	mwaitHints:     [MAX_IDLE_STATES]u32,
	idleCount:      u8,
	online:         bool,
}
#assert(size_of(CpuInfo) == 64)

CpuInfoPage :: struct {
	cpuCount: u32,
	cpus:     [0]CpuInfo,
}

cpu_infos :: proc "contextless" (page: ^CpuInfoPage) -> []CpuInfo {
	return ([^]CpuInfo)(&page.cpus)[:page.cpuCount]
}
