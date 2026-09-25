package adam
import "../lib/alloc"
import "../lib/pci"
import "../lib/pe"
import "../lib/shared"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "base:runtime"

ADAM_WEIGHT :: u64(500_000)
WORKER_WEIGHT :: u64(100_000)
WORKER_EDITED_WEIGHT :: u64(300_000)
FIRSTPE_WEIGHT :: u64(200_000)
WORKER_STACK_PAGES :: 4
SPIN_COUNTER_OFFSET :: 0x800
SETTLE_CYCLES :: u64(50_000_000)
POLL_CYCLES :: u64(100_000)
WORKER_PRINT_MASK :: u64(1) << 12 - 1
SPINNER_CODE :: [6]u8{0xF0, 0x48, 0xFF, 0x07, 0xEB, 0xFA}
#assert(SPIN_COUNTER_OFFSET >= size_of(userschedule.UserSaveArea))
#assert(ADAM_WEIGHT + WORKER_EDITED_WEIGHT <= userschedule.SCHED_WEIGHT_TOTAL)

FIRSTPE_BYTES := #load("../firstpe/firstpe.exe", []u8)
NTD_IMMITATOR_BYTE := #load("../diskimg/ntdll_immitator.dll")

@(export)
_start :: proc "c" (
	reason: syscalls.SchedulerEnterReason,
	pciesPtr: ^pci.Device,
	pciesLen: u64,
	saveArea: ^userschedule.UserSaveArea,
) -> ! {
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()
	context.temp_allocator = alloc.heap_allocator()
	context.assertion_failure_proc = adam_assertion_failure_handler

	switch reason {
	case .Start:
		adam_start()
	case .Fault:
		syscalls.grant_exit()
	}
	unreachable()
}

adam_start :: proc() -> ! {
	infos := userschedule.cpu_infos(
		(^userschedule.CpuInfoPage)(uintptr(userschedule.CPU_INFO_ADDR)),
	)
	selfCpu := syscalls.cpu_current_index()
	assert(syscalls.syscall_grant_edit_userspace(max(int), selfCpu, ADAM_WEIGHT) == .None)

	others := make([dynamic]u32)
	for &info, idx in infos {
		if u32(idx) != selfCpu && intrinsics.atomic_load(&info.online) do append(&others, u32(idx))
	}
	assert(len(others) > 0)

	test_worker_edit_kill(infos, others[0])
	syscalls.syscall_debug_print_userspace("test passed: worker edit/kill", 0)
	test_domain_destroy_while_running(infos, others[:])
	syscalls.syscall_debug_print_userspace("test passed: destroy running domain", 0)
	test_firstpe(infos, others[0])
	syscalls.syscall_debug_print_userspace("test passed: firstpe", 0)
	syscalls.grant_exit()
}

test_worker_edit_kill :: proc(infos: []userschedule.CpuInfo, cpu: u32) {
	baseline := intrinsics.atomic_load(&infos[cpu].runnableWeight)
	regions := [1]syscalls.MMapRegion {
		{pageSize = ._4KB, count = 1 + WORKER_STACK_PAGES, flags = {.Write, .NX}},
	}
	mmapErr, base := syscalls.syscall_mmap_userspace(regions[:])
	assert(mmapErr == .None)
	assert(base != nil)

	counter := new(u64)
	area := (^userschedule.UserSaveArea)(base)
	stackTop := u64(uintptr(base)) + (1 + WORKER_STACK_PAGES) * shared.PAGE_SIZE
	userschedule.save_area_init(area, u64(uintptr(rawptr(worker_entry))), stackTop - 8)
	area.rdi = u64(uintptr(counter))

	assert(syscalls.syscall_grant_spawn_userspace(max(int), cpu, area, WORKER_WEIGHT) == .None)
	assert(
		syscalls.syscall_grant_spawn_userspace(max(int), cpu, area, WORKER_WEIGHT) ==
		.AlreadyOnCpu,
	)
	assert(intrinsics.atomic_load(&infos[cpu].runnableWeight) == baseline + WORKER_WEIGHT)
	wait_counter_moves(counter)

	assert(
		syscalls.syscall_grant_edit_userspace(max(int), cpu, userschedule.SCHED_WEIGHT_TOTAL) ==
		.InsufficientWeight,
	)
	assert(syscalls.syscall_grant_edit_userspace(max(int), cpu, WORKER_EDITED_WEIGHT) == .None)
	assert(intrinsics.atomic_load(&infos[cpu].runnableWeight) == baseline + WORKER_EDITED_WEIGHT)
	wait_counter_moves(counter)

	assert(syscalls.syscall_grant_edit_userspace(max(int), cpu, 0) == .None)
	assert(syscalls.syscall_grant_edit_userspace(max(int), cpu, 0) == .NotOnCpu)
	assert(intrinsics.atomic_load(&infos[cpu].runnableWeight) == baseline)
	assert_counter_frozen(counter)

	assert(syscalls.syscall_mfree_userspace([]u64{u64(uintptr(base))}) == .None)
}

test_domain_destroy_while_running :: proc(infos: []userschedule.CpuInfo, cpus: []u32) {
	areaPages := u64(len(cpus))
	regions := [2]syscalls.MMapRegion {
		{pageSize = ._4KB, count = 1, flags = {.Write}},
		{pageSize = ._4KB, count = areaPages, flags = {.Write, .NX}},
	}
	mmapErr, base := syscalls.syscall_mmap_userspace(regions[:])
	assert(mmapErr == .None)
	assert(base != nil)
	code := u64(uintptr(base))
	areas := code + shared.PAGE_SIZE
	(^[len(SPINNER_CODE)]u8)(base)^ = SPINNER_CODE

	memRegions := [2]syscalls.MemRegion {
		{phys = code, logical = code, size = shared.PAGE_SIZE, pageSize = ._4KB, flags = {.User}},
		{
			phys = areas,
			logical = areas,
			size = areaPages * shared.PAGE_SIZE,
			pageSize = ._4KB,
			flags = {.User, .Write, .NX},
		},
	}
	createErr, handle := syscalls.syscall_prot_domain_create_userspace(new(byte), memRegions[:])
	assert(createErr == .None)

	weight := userschedule.SCHED_WEIGHT_TOTAL / areaPages
	baselines := make([]u64, len(cpus))
	counters := make([]^u64, len(cpus))
	for cpu, i in cpus {
		page := areas + u64(i) * shared.PAGE_SIZE
		area := (^userschedule.UserSaveArea)(uintptr(page))
		userschedule.save_area_init(area, code, 0)
		counters[i] = (^u64)(uintptr(page + SPIN_COUNTER_OFFSET))
		area.rdi = u64(uintptr(counters[i]))
		baselines[i] = intrinsics.atomic_load(&infos[cpu].runnableWeight)
		assert(syscalls.syscall_grant_spawn_userspace(handle, cpu, area, weight) == .None)
	}
	for counter in counters do wait_counter_moves(counter)

	assert(syscalls.syscall_prot_domain_destroy_userspace(handle) == .None)
	for cpu, i in cpus {
		assert(intrinsics.atomic_load(&infos[cpu].runnableWeight) == baselines[i])
	}
	for counter in counters do assert_counter_frozen(counter)
	assert(syscalls.syscall_grant_edit_userspace(handle, cpus[0], weight) == .InvalidHandle)

	assert(syscalls.syscall_mfree_userspace([]u64{code, areas}) == .None)
}

test_firstpe :: proc(infos: []userschedule.CpuInfo, cpu: u32) {
	baseline := intrinsics.atomic_load(&infos[cpu].runnableWeight)
	_, ntdllOk := pe.register("ntdll.dll", NTD_IMMITATOR_BYTE)
	assert(ntdllOk)
	syscalls.syscall_debug_print_userspace("firstpe: ntdll registered", 0)
	firstpe, loadOk := pe.load(FIRSTPE_BYTES)
	assert(loadOk)
	syscalls.syscall_debug_print_userspace("firstpe: loaded at", firstpe.base)

	handle, runErr := pe.pe_run(&firstpe, firstpe.image.entryRva, cpu, FIRSTPE_WEIGHT)
	syscalls.syscall_debug_print_userspace("firstpe: pe_run err", u64(runErr))
	assert(runErr == .None)
	polls: u64
	for syscalls.syscall_grant_edit_userspace(handle, cpu, FIRSTPE_WEIGHT) == .None {
		if polls & WORKER_PRINT_MASK == 0 {
			syscalls.syscall_debug_print_userspace("firstpe: still running, polls", polls)
		}
		polls += 1
		delay_cycles(POLL_CYCLES)
	}
	assert(intrinsics.atomic_load(&infos[cpu].runnableWeight) == baseline)
	assert(syscalls.syscall_prot_domain_destroy_userspace(handle) == .None)
}

wait_counter_moves :: proc(counter: ^u64) {
	start := intrinsics.atomic_load(counter)
	for intrinsics.atomic_load(counter) == start do intrinsics.cpu_relax()
}

assert_counter_frozen :: proc(counter: ^u64) {
	delay_cycles(SETTLE_CYCLES)
	seen := intrinsics.atomic_load(counter)
	delay_cycles(SETTLE_CYCLES)
	assert(intrinsics.atomic_load(counter) == seen)
}

delay_cycles :: proc(cycles: u64) {
	start := u64(intrinsics.read_cycle_counter())
	for u64(intrinsics.read_cycle_counter()) - start < cycles do intrinsics.cpu_relax()
}

worker_entry :: proc "c" (counter: ^u64) -> ! {
	for {intrinsics.atomic_add(counter, 1)}
}
