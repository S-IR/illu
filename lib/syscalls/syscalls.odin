package syscalls
import "../lmem"
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

Syscall :: enum u64 {
	Exit = ILLU_SYSCALL_BIT,
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
	AttachmentSet,
	AttachmentRemove,
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

AttachmentSetError :: enum u64 {
	None,
	NoPermission,
	InvalidHandle,
	InvalidEntry,
}

AttachmentRemoveError :: enum u64 {
	None,
	NoPermission,
	InvalidHandle,
}


when !ODIN_TEST {
	when !KERNEL_BUILD {
		@(default_calling_convention = "sysv")
		foreign _ {
			syscall_exit :: proc(code: u64) -> ! ---
			syscall_mmap :: proc(regionsPtr: u64, regionCount: u64) -> (err: u64, addr: u64) ---
			syscall_mfree :: proc(addrsPtr: u64, count: u64) -> (err: u64) ---
			syscall_interrupt_vector_get :: proc(resource_phys: u64) -> (err: u64, vector: u64) ---
			syscall_interrupt_wait :: proc(vector: u64) -> (err: u64) ---
			syscall_multiplexed_memory_create :: proc(phys, size: u64) -> (err: u64, handle: u64) ---
			syscall_multiplexed_memory_read :: proc(handle, offset, dest, size, width: u64) -> (err: u64) ---
			syscall_multiplexed_memory_write :: proc(handle, offset, source, size, width: u64) -> (err: u64) ---
			syscall_prot_domain_create :: proc(regionsPtr, count: u64) -> (err: u64, handle: u64) ---
			syscall_prot_domain_edit :: proc(handle, regionsPtr, count, op: u64) -> (err: u64) ---
			syscall_prot_domain_destroy :: proc(handle: u64) -> (err: u64) ---
			syscall_execution_start :: proc(handle, entryRip, entryRsp, arg0, arg1: u64) -> (err: u64) ---
			syscall_attachment_set :: proc(handle, entryRip: u64) -> (err: u64) ---
			syscall_attachment_remove :: proc(handle: u64) -> (err: u64) ---

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

		syscall_attachment_set_userspace :: proc "contextless" (
			handle, entryRip: u64,
		) -> AttachmentSetError {
			return AttachmentSetError(syscall_attachment_set(handle, entryRip))
		}

		syscall_attachment_remove_userspace :: proc "contextless" (
			handle: u64,
		) -> AttachmentRemoveError {
			return AttachmentRemoveError(syscall_attachment_remove(handle))
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

