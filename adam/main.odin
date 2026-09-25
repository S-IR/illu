package adam
import "../lib/alloc"
import "../lib/lmem"
import "../lib/pci"
import "../lib/pe"
import "../lib/shared"
import "../lib/syscalls"
import "base:intrinsics"
import "base:runtime"
import "core:mem"

WORKER_COUNT :: 3
WORKER_WEIGHT :: u64(200_000)
WORKER_PAGES :: 5
WORKER_PRINT_MASK :: u64(1) << 24 - 1
FX_FCW_DEFAULT :: u16(0x037F)
MXCSR_DEFAULT :: u32(0x1F80)
FX_MXCSR_OFFSET :: 24

FIRSTPE_BYTES := #load("../firstpe/firstpe.exe", []u8)

NTD_IMMITATOR_BYTE := #load("../diskimg/ntdll_immitator.dll")

@(export)
_start :: proc "c" (
	reason: syscalls.SchedulerEnterReason,
	pciesPtr: ^pci.Device,
	pciesLen: u64,
	saveArea: ^syscalls.UserSaveArea,
) -> ! {
	context = runtime.default_context()
	context.allocator = alloc.heap_allocator()
	context.temp_allocator = alloc.heap_allocator()
	context.assertion_failure_proc = adam_assertion_failure_handler

	switch reason {
	case .Start:
		adam_start(pciesPtr, pciesLen)
	case .Fault:
		syscalls.grant_exit()
	}
	unreachable()
}

adam_start :: proc(pciesPtr: ^pci.Device, pciesLen: u64) -> ! {
	_ = pciesPtr
	_ = pciesLen

	infos := syscalls.cpu_infos((^syscalls.CpuInfoPage)(uintptr(syscalls.CPU_INFO_ADDR)))
	selfCpu := syscalls.cpu_current_index()
	when ODIN_DEBUG {
		syscalls.syscall_debug_print_userspace("adam cpu", u64(selfCpu))
		syscalls.syscall_debug_print_userspace("cpu count", u64(len(infos)))
		for &info, idx in infos {
			syscalls.syscall_debug_print_userspace("cpu", u64(idx))
			syscalls.syscall_debug_print_userspace(
				"  online",
				intrinsics.atomic_load(&info.online) ? 1 : 0,
			)
			syscalls.syscall_debug_print_userspace(
				"  runnableWeight",
				intrinsics.atomic_load(&info.runnableWeight),
			)
		}
	}

	editErr := syscalls.syscall_grant_edit_userspace(
		max(int),
		selfCpu,
		syscalls.SCHED_WEIGHT_TOTAL - WORKER_COUNT * WORKER_WEIGHT,
	)
	assert(editErr == .None)

	regions := [1]syscalls.MMapRegion {
		{pageSize = ._4KB, count = WORKER_COUNT * WORKER_PAGES, flags = {.Present, .Write, .NX}},
	}
	mmapErr, base := syscalls.syscall_mmap_userspace(regions[:])
	assert(mmapErr == .None)
	assert(base != nil)

	spawned := 0
	for &info, cpuIdx in infos {
		if spawned == WORKER_COUNT do break
		if u32(cpuIdx) == selfCpu || !intrinsics.atomic_load(&info.online) do continue

		workerBase := uintptr(base) + uintptr(spawned * WORKER_PAGES * shared.PAGE_SIZE)
		area := (^syscalls.UserSaveArea)(workerBase)
		area^ = {
			rip    = u64(uintptr(rawptr(worker_entry))),
			rsp    = u64(workerBase) + WORKER_PAGES * shared.PAGE_SIZE - 8,
			rflags = 0x202,
		}
		(^u16)(&area.fx[0])^ = FX_FCW_DEFAULT
		(^u32)(&area.fx[FX_MXCSR_OFFSET])^ = MXCSR_DEFAULT

		spawnErr := syscalls.syscall_grant_spawn_userspace(
			max(int),
			u32(cpuIdx),
			area,
			WORKER_WEIGHT,
		)
		when ODIN_DEBUG {
			syscalls.syscall_debug_print_userspace("spawn on cpu", u64(cpuIdx))
			syscalls.syscall_debug_print_userspace("  result", u64(spawnErr))
		}
		assert(spawnErr == .None)
		spawned += 1
	}

	counter: u64
	for {
		if counter & WORKER_PRINT_MASK == 0 {
			when ODIN_DEBUG {
				syscalls.syscall_debug_print_userspace(
					"adam alive on cpu",
					u64(syscalls.cpu_current_index()),
				)
			}
		}
		counter += 1
	}
}

worker_entry :: proc "c" () -> ! {
	counter: u64
	for {
		if counter & WORKER_PRINT_MASK == 0 {
			when ODIN_DEBUG {
				syscalls.syscall_debug_print_userspace(
					"worker alive on cpu",
					u64(syscalls.cpu_current_index()),
				)
			}
		}
		counter += 1
	}
}
