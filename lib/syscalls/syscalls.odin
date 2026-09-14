package syscalls
import "../lmem"

MemRegion :: struct #packed {
	phys, logical, size: u64,
	pageSize:            lmem.PageSize,
	flags:               lmem.PageFlags,
}
Syscall :: enum {
	Exit,
	MMap,
	MFree,
	InterruptVectorGet,
	InterruptWait,
	MultiplexedMemoryCreate,
	MultiplexedMemoryRead,
	MultiplexedMemoryWrite,
	ProtDomainCreate,
	ProtDomainEdit,
	ProtDomainDestroy,
	ExecutionStart,
	// Parked at a high, isolated number (debug-build only, see ODIN_DEBUG
	// below) so it never collides with a real syscall number as the table
	// above grows.
	DebugPrint = 1000,
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
}

InterruptVectorGetError :: enum u64 {
	None,
	NoPermission,
	NoVectors,
}

InterruptWaitError :: enum u64 {
	None,
	NoPermission,
	InvalidVector,
	AlreadyWaiting,
}

MultiplexedMemoryError :: enum u64 {
	None,
	NoPermission,
	InvalidHandle,
	InvalidRange,
	InvalidBuffer,
	InvalidWidth,
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
}

ProtDomainDestroyError :: enum u64 {
	None,
	InvalidHandle,
}

ExecutionStartError :: enum u64 {
	None,
	NoPermission,
	InvalidHandle,
	InvalidEntry,
	OutOfMemory,
}

KERNEL_BUILD :: #config(KERNEL_BUILD, false)


when !ODIN_TEST {
	when !KERNEL_BUILD {
		@(default_calling_convention = "sysv")
		foreign _ {
			syscall_exit :: proc(code: u64) -> ! ---
			syscall_mmap :: proc(count: u64, size: u64, flagsPtr: u64) -> (err: u64, addr: u64) ---
			syscall_mfree :: proc(addr: u64) -> (err: u64) ---
			syscall_interrupt_vector_get :: proc(resource_phys: u64) -> (err: u64, vector: u64) ---
			syscall_interrupt_wait :: proc(vector: u64) -> (err: u64) ---
			syscall_multiplexed_memory_create :: proc(phys, size: u64) -> (err: u64, handle: u64) ---
			syscall_multiplexed_memory_read :: proc(handle, offset, dest, size, width: u64) -> (err: u64) ---
			syscall_multiplexed_memory_write :: proc(handle, offset, source, size, width: u64) -> (err: u64) ---
			syscall_prot_domain_create :: proc(regionsPtr, count: u64) -> (err: u64, handle: u64) ---
			syscall_prot_domain_edit :: proc(handle, regionsPtr, count, op: u64) -> (err: u64) ---
			syscall_prot_domain_destroy :: proc(handle: u64) -> (err: u64) ---
			syscall_execution_start :: proc(handle, entryRip, entryRsp, arg0, arg1: u64) -> (err: u64) ---
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
			count: u64,
			size: lmem.PageSize,
			flags: lmem.PageFlags,
		) -> (
			err: MMapError,
			addr: rawptr,
		) {
			rawErr, rawAddr := syscall_mmap(count, u64(size), transmute(u64)flags)
			return MMapError(rawErr), rawptr(uintptr(rawAddr))
		}

		syscall_mfree_userspace :: proc "contextless" (addr: u64) -> (err: MFreeError) {
			return MFreeError(syscall_mfree(addr))
		}

		syscall_interrupt_vector_get_userspace :: proc "contextless" (
			resource_phys: u64,
		) -> (
			err: InterruptVectorGetError,
			vector: u8,
			lapic_id: u32,
		) {
			rawErr, packed := syscall_interrupt_vector_get(resource_phys)
			return InterruptVectorGetError(rawErr), u8(packed & 0xFF), u32(packed >> 8)
		}

		syscall_interrupt_wait_userspace :: proc "contextless" (
			vector: u8,
		) -> (
			err: InterruptWaitError,
		) {
			return InterruptWaitError(syscall_interrupt_wait(u64(vector)))
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
			regions: []MemRegion,
		) -> (
			err: ProtDomainCreateError,
			handle: u64,
		) {
			rawErr, rawHandle := syscall_prot_domain_create(
				u64(uintptr(raw_data(regions))),
				u64(len(regions)),
			)
			return ProtDomainCreateError(rawErr), rawHandle
		}

		syscall_prot_domain_edit_userspace :: proc "contextless" (
			handle: u64,
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
			handle: u64,
		) -> (
			err: ProtDomainDestroyError,
		) {
			return ProtDomainDestroyError(syscall_prot_domain_destroy(handle))
		}

		syscall_execution_start_userspace :: proc "contextless" (
			handle, entryRip, entryRsp, arg0, arg1: u64,
		) -> (
			err: ExecutionStartError,
		) {
			return ExecutionStartError(
				syscall_execution_start(handle, entryRip, entryRsp, arg0, arg1),
			)
		}
	}
}
