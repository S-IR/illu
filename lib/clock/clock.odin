package clock

import "../userschedule"
import "base:intrinsics"

ticks_per_ms :: proc() -> u64 {
	page := (^userschedule.CpuInfoPage)(uintptr(userschedule.CPU_INFO_ADDR))
	assert(page.tscTicksPerMs != 0)
	return page.tscTicksPerMs
}

now :: proc() -> u64 {
	return u64(intrinsics.read_cycle_counter())
}

deadline_after_ms :: proc(ms: u64) -> u64 {
	perMs := ticks_per_ms()
	assert(ms <= max(u64) / perMs)
	start := now()
	assert(ms * perMs <= max(u64) - start)
	return start + ms * perMs
}

expired :: proc(deadline: u64) -> bool {
	return now() >= deadline
}
