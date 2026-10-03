package syscalls
import "../lmem"
import "../userschedule"
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
MAX_REGIONS_PER_CALL :: 64
SchedulerEnterReason :: enum u64 {
	Start,
	Fault,
	Resume,
}



Syscall :: enum u64 {
	MMap = ILLU_SYSCALL_BIT,
	ProtDomainCreate,
	ProtDomainEdit,
	ProtDomainDestroy,
	GrantSpawn,
	GrantEdit,
	WaitOn,
	DebugPrint = ILLU_SYSCALL_BIT + 1000,
}

MMapError :: enum u64 {
	None,
	InvalidPageSize,
	OutOfMemory,
	InvalidSize,
	AddressInUse,
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
	InvalidEntry,
}
ProtDomainDestroyError :: enum u64 {
	None,
	InvalidHandle,
}
WaitOnError :: enum u64 {
	None,
	TimedOut,
	InvalidAddress,
	InvalidSaveArea,
}
KERNEL_BUILD :: #config(KERNEL_BUILD, false)

when !ODIN_TEST {
	when !KERNEL_BUILD {
		@(default_calling_convention = "sysv")
		foreign _ {
			syscall_mmap :: proc(regionsPtr: u64, regionCount: u64) -> (err: u64, addr: u64) ---
			syscall_prot_domain_create :: proc(authorityPtr, regionsPtr, count: u64) -> (err: u64, handle: int) ---
			syscall_prot_domain_edit :: proc(handle: int, regionsPtr, count, op: u64) -> (err: u64) ---
			syscall_prot_domain_destroy :: proc(handle: int) -> (err: u64) ---
			syscall_grant_spawn :: proc(handle: int, cpu: u64, saveArea: u64, weight: u64, entry: u64) -> (err: u64) ---
			syscall_grant_edit :: proc(handle: int, cpu: u64, weight: u64) -> (err: u64) ---
			syscall_wait_on :: proc(addr, oldValue, deadline: u64) -> (err: u64) ---
			cpu_current_index :: proc() -> u32 ---
			user_resume :: proc() ---
		}

		syscall_grant_spawn_userspace :: proc "contextless" (
			handle: int,
			cpu: u32,
			saveArea: ^userschedule.UserSaveArea,
			weight: u64,
			entry: u64,
		) -> GrantError {
			return GrantError(
				syscall_grant_spawn(handle, u64(cpu), u64(uintptr(saveArea)), weight, entry),
			)
		}

		syscall_grant_edit_userspace :: proc "contextless" (
			handle: int,
			cpu: u32,
			weight: u64,
		) -> GrantError {
			return GrantError(syscall_grant_edit(handle, u64(cpu), weight))
		}

		syscall_wait_on_userspace :: proc "contextless" (addr: ^u64, oldValue, deadline: u64) -> WaitOnError {
			assert_contextless(uintptr(addr) % 8 == 0)
			return WaitOnError(syscall_wait_on(u64(uintptr(addr)), oldValue, deadline))
		}

		grant_exit :: proc "contextless" () -> ! {
			syscall_grant_edit(max(int), u64(cpu_current_index()), 0)
			intrinsics.trap()
		}

		@(default_calling_convention = "sysv")
		foreign _ {
			syscall_debug_print :: proc(labelPtr: rawptr, labelLen: u64, value: u64) ---
		}

		syscall_debug_print_userspace :: proc "contextless" (label: string, value: u64) {
			syscall_debug_print(raw_data(label), u64(len(label)), value)
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

		mem_free_userspace :: proc "contextless" (phys: u64) -> ProtDomainEditError {
			regions := [1]MemRegion{{phys = phys}}
			return syscall_prot_domain_edit_userspace(max(int), regions[:], .Delete)
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
} else {
	syscall_wait_on_userspace :: proc "contextless" (addr: ^u64, oldValue, deadline: u64) -> WaitOnError {
		return .None
	}
}

descriptor_offset :: proc(regions: []MMapRegion, index: int) -> u64 {
	offset: u64 = 0
	for r, i in regions[:index + 1] {
		pageBytes := lmem.page_bytes(r.pageSize)
		offset = (offset + pageBytes - 1) & ~(pageBytes - 1)
		if i < index do offset += r.count * pageBytes
	}
	return offset
}
