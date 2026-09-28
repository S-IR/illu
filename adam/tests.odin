package adam

import "../lib/shared"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"

@(default_calling_convention = "c")
foreign _ {
	cpu_has_avx :: proc() -> bool ---
	avx_check_worker :: proc() ---
}

TEST_DESTROY_ROUNDS :: 20
TEST_LARGE_PAGE_ROUNDS :: 8
TWO_MB :: u64(2 * 1024 * 1024)
AVX_REGISTERS :: 15
AVX_REGISTER_BYTES :: 32
AVX_WORKER_WEIGHT :: u64(100_000)
#assert(ADAM_WEIGHT + 3 * AVX_WORKER_WEIGHT <= userschedule.SCHED_WEIGHT_TOTAL)
AVX_SETTLE_CYCLES :: SETTLE_CYCLES * 20
WEIGHT_WAIT_POLLS :: 100_000

AvxStatus :: struct {
	iterations, failures: u64,
}
AvxPatterns :: [AVX_REGISTERS * AVX_REGISTER_BYTES / size_of(u64)]u64

run_kernel_tests :: proc() {
	infos := userschedule.cpu_infos((^userschedule.CpuInfoPage)(uintptr(userschedule.CPU_INFO_ADDR)))
	selfCpu := syscalls.cpu_current_index()
	assert(syscalls.syscall_grant_edit_userspace(max(int), selfCpu, ADAM_WEIGHT) == .None)

	others := make([dynamic]u32)
	for &info, idx in infos {
		if u32(idx) != selfCpu && intrinsics.atomic_load(&info.online) do append(&others, u32(idx))
	}
	assert(len(others) > 0)

	test_worker_edit_kill(infos, others[0])
	test_pass("worker edit/kill")
	for _ in 0 ..< TEST_DESTROY_ROUNDS do test_domain_destroy_while_running(infos, others[:])
	test_pass("destroy running domain, repeated")
	test_shootdown_while_running(infos, others[:])
	test_pass("unmap from running domain on all cpus")
	test_large_pages()
	test_pass("2MB pages")
	if cpu_has_avx() {
		test_avx_preserved(infos, others[:])
		test_pass("avx state across preemption + xsave mask")
	} else {
		syscalls.syscall_debug_print_userspace("test skipped: no avx", 0)
	}
	test_firstpe(infos, others[0])
	test_pass("firstpe")
	spawn_printers(others[:])
}

test_pass :: proc(name: string) {
	syscalls.syscall_debug_print_userspace(name, 1)
}

wait_runnable_weight :: proc(info: ^userschedule.CpuInfo, weight: u64) {
	for _ in 0 ..< WEIGHT_WAIT_POLLS {
		if intrinsics.atomic_load(&info.runnableWeight) == weight do return
		delay_cycles(POLL_CYCLES)
	}
	assert(intrinsics.atomic_load(&info.runnableWeight) == weight)
}

test_shootdown_while_running :: proc(infos: []userschedule.CpuInfo, cpus: []u32) {
	areaPages := u64(len(cpus))
	regions := [2]syscalls.MMapRegion {
		{pageSize = ._4KB, count = 1, flags = {.Write}},
		{pageSize = ._4KB, count = areaPages, flags = {.Write, .NX}},
	}
	mmapErr, base := syscalls.syscall_mmap_userspace(regions[:])
	assert(mmapErr == .None)
	code := u64(uintptr(base))
	areas := code + syscalls.descriptor_offset(regions[:], 1)
	(^[len(SPINNER_CODE)]u8)(base)^ = SPINNER_CODE

	memRegions := [2]syscalls.MemRegion {
		{phys = code, logical = code, size = shared.PAGE_SIZE, pageSize = ._4KB},
		{phys = areas, logical = areas, size = areaPages * shared.PAGE_SIZE, pageSize = ._4KB, flags = {.Write, .NX}},
	}
	createErr, handle := syscalls.syscall_prot_domain_create_userspace(new(byte), memRegions[:])
	assert(createErr == .None)

	weight := userschedule.SCHED_WEIGHT_TOTAL / areaPages
	baselines := make([]u64, len(cpus))
	counters := make([]^u64, len(cpus))
	for cpu, i in cpus {
		page := areas + u64(i) * shared.PAGE_SIZE
		counters[i] = (^u64)(uintptr(page + SPIN_COUNTER_OFFSET))
		baselines[i] = intrinsics.atomic_load(&infos[cpu].runnableWeight)
		area := (^userschedule.UserSaveArea)(uintptr(page))
		assert(syscalls.syscall_grant_spawn_userspace(handle, cpu, area, weight, code) == .None)
	}
	for counter in counters do wait_counter_moves(counter)

	syscalls.syscall_debug_print_userspace("expect one domain fault per cpu", u64(len(cpus)))
	deleteRegions := [1]syscalls.MemRegion{{phys = areas}}
	assert(syscalls.syscall_prot_domain_edit_userspace(handle, deleteRegions[:], .Delete) == .None)
	for counter in counters do assert_counter_frozen(counter)
	for cpu, i in cpus do wait_runnable_weight(&infos[cpu], baselines[i])

	assert(syscalls.syscall_prot_domain_destroy_userspace(handle) == .None)
	assert(syscalls.mem_free_userspace(code) == .None)
	assert(syscalls.mem_free_userspace(areas) == .None)
}

test_large_pages :: proc() {
	for _ in 0 ..< TEST_LARGE_PAGE_ROUNDS {
		regions := [2]syscalls.MMapRegion {
			{pageSize = ._4KB, count = 1, flags = {.Write, .NX}},
			{pageSize = ._2MB, count = 1, flags = {.Write, .NX}},
		}
		mmapErr, base := syscalls.syscall_mmap_userspace(regions[:])
		assert(mmapErr == .None)
		small := u64(uintptr(base))
		large := small + syscalls.descriptor_offset(regions[:], 1)
		assert(large % TWO_MB == 0)

		first := (^u64)(uintptr(large))
		last := (^u64)(uintptr(large + TWO_MB - size_of(u64)))
		assert(first^ == 0 && last^ == 0)
		first^ = 0x1122_3344
		last^ = 0x5566_7788
		assert(first^ == 0x1122_3344 && last^ == 0x5566_7788)

		assert(syscalls.mem_free_userspace(small) == .None)
		assert(syscalls.mem_free_userspace(large) == .None)
	}
}

test_avx_preserved :: proc(infos: []userschedule.CpuInfo, cpus: []u32) {
	workers := len(cpus)
	maskedWorker := workers - 1
	assert(workers >= 2)
	baselines := make([]u64, workers)
	regions := [1]syscalls.MMapRegion{{pageSize = ._4KB, count = u64(workers), flags = {.Write, .NX}}}
	mmapErr, base := syscalls.syscall_mmap_userspace(regions[:])
	assert(mmapErr == .None)

	statuses := make([]AvxStatus, workers)
	patterns := make([]AvxPatterns, workers)
	entry := u64(uintptr(rawptr(syscalls.user_resume)))
	for cpu, w in cpus {
		for &value, i in patterns[w] do value = u64(w + 1) << 56 | u64(i + 1) * 0x0101_0101
		page := u64(uintptr(base)) + u64(w) * shared.PAGE_SIZE
		area := (^userschedule.UserSaveArea)(uintptr(page))
		userschedule.save_area_init(area, u64(uintptr(rawptr(avx_check_worker))), page + shared.PAGE_SIZE - 8)
		area.rdi = u64(uintptr(&statuses[w]))
		area.rsi = u64(uintptr(&patterns[w]))
		if w == maskedWorker do area.xsaveMask = 0b11
		baselines[w] = intrinsics.atomic_load(&infos[cpu].runnableWeight)
		assert(syscalls.syscall_grant_spawn_userspace(max(int), cpu, area, AVX_WORKER_WEIGHT, entry) == .None)
	}
	delay_cycles(AVX_SETTLE_CYCLES)

	for &status, w in statuses {
		assert(intrinsics.atomic_load(&status.iterations) > 0)
		failures := intrinsics.atomic_load(&status.failures)
		if w == maskedWorker {
			assert(failures > 0)
		} else {
			assert(failures == 0)
		}
	}
	for cpu, w in cpus {
		assert(syscalls.syscall_grant_edit_userspace(max(int), cpu, 0) == .None)
		wait_runnable_weight(&infos[cpu], baselines[w])
	}
	assert(syscalls.mem_free_userspace(u64(uintptr(base))) == .None)
}
