package syscalls
import "../lmem"
import "base:intrinsics"
import "core:mem"
MemRegion :: struct #packed {
	phys, logical, size: u64,
	pageSize:            lmem.PageSize,
	flags:               lmem.PageFlags,
}
MMapRegion :: struct #packed {
	pageSize: lmem.PageSize,
	count:    u64,
	flags:    lmem.PageFlags,
}
ILLU_SYSCALL_BIT :: u64(1) << 63
SchedulerEnterReason :: enum u64 {
	Start,
	Fault,
}

UserSaveArea :: struct #align (64) {
	fx:                                   [512]u8,
	rax, rbx, rcx, rdx, rsi, rdi, rbp:    u64,
	r8, r9, r10, r11, r12, r13, r14, r15: u64,
	rip, rsp, rflags:                     u64,
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

GrantSaveAreaError :: enum u64 {
	None,
	Misaligned,
	NoPermission,
}

Syscall :: enum u64 {
	MMap = ILLU_SYSCALL_BIT,
	MFree,
	MultiplexedMemoryCreate,
	MultiplexedMemoryRead,
	MultiplexedMemoryWrite,
	ProtDomainCreate,
	ProtDomainEdit,
	ProtDomainDestroy,
	GrantSpawn,
	GrantEdit,
	// Parked at a high, isolated number (debug-build only, see ODIN_DEBUG
	// below) so it never collides with a real syscall number as the table
	// above grows.
	DebugPrint = ILLU_SYSCALL_BIT + 1000,
}

MMapError :: enum u64 {
	None,
	InvalidPageSize,
	OutOfMemory,
	InvalidSize,
	TrackingFailed,
}

MFreeError :: enum u64 {
	None,
	InvalidAddress,
	InvalidSize,
	OutOfMemory,
}

MultiplexedMemoryError :: enum u64 {
	None,
	NoPermission,
	InvalidHandle,
	InvalidRange,
	InvalidBuffer,
	InvalidWidth,
	OutOfMemory,
}

ProtDomainCreateError :: enum u64 {
	None,
	NoPermission,
	InvalidRegionCount,
	InvalidRegion,
	NotOwned,
	OutOfMemory,
	TrackingFailed,
}

MemRegionOp :: enum u8 {
	Add,
	Delete,
}

ProtDomainEditError :: enum u64 {
	None,
	NoPermission,
	InvalidHandle,
	InvalidRegionCount,
	InvalidRegion,
	NotOwned,
	NotFound,
	InvalidOp,
	TrackingFailed,
	OutOfMemory,
}
GrantError :: enum u64 {
	None,
	InvalidHandle,
	NoPermission,
	InvalidCpu,
	InvalidSaveArea,
	AlreadyOnCpu,
	NotOnCpu,
	InsufficientWeight,
	OutOfMemory,
}
ProtDomainDestroyError :: enum u64 {
	None,
	InvalidHandle,
}

KERNEL_BUILD :: #config(KERNEL_BUILD, false)

when !ODIN_TEST {
	when !KERNEL_BUILD {
		@(default_calling_convention = "sysv")
		foreign _ {
			syscall_mmap :: proc(regionsPtr: u64, regionCount: u64) -> (err: u64, addr: u64) ---
			syscall_mfree :: proc(addrsPtr: u64, count: u64) -> (err: u64) ---
			syscall_multiplexed_memory_create :: proc(phys, size: u64) -> (err: u64, handle: u64) ---
			syscall_multiplexed_memory_read :: proc(handle, offset, dest, size, width: u64) -> (err: u64) ---
			syscall_multiplexed_memory_write :: proc(handle, offset, source, size, width: u64) -> (err: u64) ---
			syscall_prot_domain_create :: proc(authorityPtr, regionsPtr, count: u64) -> (err: u64, handle: int) ---
			syscall_prot_domain_edit :: proc(handle: int, regionsPtr, count, op: u64) -> (err: u64) ---
			syscall_prot_domain_destroy :: proc(handle: int) -> (err: u64) ---
			syscall_grant_spawn :: proc(handle: int, cpu: u32, saveArea: u64, weight: u64) -> (err: u64) ---
			syscall_grant_edit :: proc(handle: int, cpu: u32, weight: u64) -> (err: u64) ---
			cpu_current_index :: proc() -> u32 ---
		}

		syscall_grant_spawn_userspace :: proc "contextless" (
			handle: int,
			cpu: u32,
			saveArea: ^UserSaveArea,
			weight: u64,
		) -> GrantError {
			return GrantError(syscall_grant_spawn(handle, cpu, u64(uintptr(saveArea)), weight))
		}

		syscall_grant_edit_userspace :: proc "contextless" (
			handle: int,
			cpu: u32,
			weight: u64,
		) -> GrantError {
			return GrantError(syscall_grant_edit(handle, cpu, weight))
		}

		grant_exit :: proc "contextless" () -> ! {
			syscall_grant_edit(max(int), cpu_current_index(), 0)
			intrinsics.trap()
		}

		// Debug-only: writes `label: value (0xvalue)` to the kernel serial
		// log. `label` is read directly out of adam's (identity-mapped)
		// memory by the kernel -- same trust model as every other pointer
		// adam already hands the kernel elsewhere in this syscall table, and
		// fine for a debug-only path. Not gated by a protection domain
		// permission, and only linked into -debug builds (see ODIN_DEBUG)
		// -- never reachable from a release binary.
		when ODIN_DEBUG {
			@(default_calling_convention = "sysv")
			foreign _ {
				syscall_debug_print :: proc(labelPtr: rawptr, labelLen: u64, value: u64) ---
			}

			syscall_debug_print_userspace :: proc "contextless" (label: string, value: u64) {
				syscall_debug_print(raw_data(label), u64(len(label)), value)
			}
		}

		syscall_mmap_userspace :: proc "contextless" (
			regions: []MMapRegion,
		) -> (
			err: MMapError,
			addr: rawptr,
		) {
			if regions == nil || len(regions) == 0 do return .InvalidSize, nil

			rawErr, rawAddr := syscall_mmap(u64(uintptr(raw_data(regions))), u64(len(regions)))
			return MMapError(rawErr), rawptr(uintptr(rawAddr))
		}

		syscall_mfree_userspace :: proc "contextless" (addrs: []u64) -> (err: MFreeError) {
			if len(addrs) == 0 do return .InvalidAddress
			return MFreeError(syscall_mfree(u64(uintptr(raw_data(addrs))), u64(len(addrs))))
		}

		syscall_multiplexed_memory_create_userspace :: proc "contextless" (
			phys, size: u64,
		) -> (
			err: MultiplexedMemoryError,
			handle: u64,
		) {
			rawErr, rawHandle := syscall_multiplexed_memory_create(phys, size)
			return MultiplexedMemoryError(rawErr), rawHandle
		}

		syscall_multiplexed_memory_read_userspace :: proc "contextless" (
			handle, offset: u64,
			dest: rawptr,
			size, width: u64,
		) -> MultiplexedMemoryError {
			return MultiplexedMemoryError(
				syscall_multiplexed_memory_read(handle, offset, u64(uintptr(dest)), size, width),
			)
		}

		syscall_multiplexed_memory_write_userspace :: proc "contextless" (
			handle, offset: u64,
			source: rawptr,
			size, width: u64,
		) -> MultiplexedMemoryError {
			return MultiplexedMemoryError(
				syscall_multiplexed_memory_write(
					handle,
					offset,
					u64(uintptr(source)),
					size,
					width,
				),
			)
		}

		syscall_prot_domain_create_userspace :: proc "contextless" (
			authorityPtr: rawptr,
			regions: []MemRegion,
		) -> (
			err: ProtDomainCreateError,
			handle: int,
		) {
			rawErr, rawHandle := syscall_prot_domain_create(
				u64(uintptr(authorityPtr)),
				u64(uintptr(raw_data(regions))),
				u64(len(regions)),
			)
			return ProtDomainCreateError(rawErr), rawHandle
		}

		syscall_prot_domain_edit_userspace :: proc "contextless" (
			handle: int,
			regions: []MemRegion,
			op: MemRegionOp,
		) -> (
			err: ProtDomainEditError,
		) {
			return ProtDomainEditError(
				syscall_prot_domain_edit(
					handle,
					u64(uintptr(raw_data(regions))),
					u64(len(regions)),
					u64(op),
				),
			)
		}

		syscall_prot_domain_destroy_userspace :: proc "contextless" (
			handle: int,
		) -> (
			err: ProtDomainDestroyError,
		) {
			return ProtDomainDestroyError(syscall_prot_domain_destroy(handle))
		}

	}
}

descriptor_offset :: proc(regions: []MMapRegion, index: int) -> u64 {
	offset: u64 = 0
	for i in 0 ..< index {
		offset += regions[i].count * mmap_page_size_bytes(regions[i].pageSize)
	}
	return offset
}
mmap_page_size_bytes :: proc "contextless" (size: lmem.PageSize) -> u64 {
	switch size {
	case ._4KB:
		return 4 * mem.Kilobyte
	case ._2MB:
		return 2 * mem.Megabyte
	case ._1GB:
		return mem.Gigabyte
	}
	return 0
}


SCHED_WEIGHT_TOTAL :: u64(1_000_000)

CPU_INFO_ADDR :: u64(0x7FF0_0000_0000)

CpuInfo :: struct #align (64) {
	runnableWeight: u64,
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
