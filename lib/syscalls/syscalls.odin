package syscalls
import "../lmem"

Syscall :: enum {
	Exit,
	MMap,
	MFree,
	InterruptVectorGet,
	InterruptWait,
	MultiplexedMemoryCreate,
	MultiplexedMemoryRead,
	MultiplexedMemoryWrite,
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

KERNEL_BUILD :: #config(KERNEL_BUILD, false)


when !ODIN_TEST {
	when !KERNEL_BUILD {
		@(default_calling_convention = "sysv")
		foreign _ {
			syscall_exit :: proc(code: u64) -> ! ---
			syscall_mmap :: proc(count: u64, size: u64, flags: u64) -> (err: u64, addr: u64) ---
			syscall_mfree :: proc(addr: u64) -> (err: u64) ---
			syscall_interrupt_vector_get :: proc(resource_phys: u64) -> (err: u64, vector: u64) ---
			syscall_interrupt_wait :: proc(vector: u64) -> (err: u64) ---
			syscall_multiplexed_memory_create :: proc(phys, size: u64) -> (err: u64, handle: u64) ---
			syscall_multiplexed_memory_read :: proc(handle, offset, dest, size, width: u64) -> (err: u64) ---
			syscall_multiplexed_memory_write :: proc(handle, offset, source, size, width: u64) -> (err: u64) ---
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
		) -> (err: MultiplexedMemoryError, handle: u64) {
			rawErr, rawHandle := syscall_multiplexed_memory_create(phys, size)
			return MultiplexedMemoryError(rawErr), rawHandle
		}

		syscall_multiplexed_memory_read_userspace :: proc "contextless" (
			handle, offset: u64,
			dest: rawptr,
			size, width: u64,
		) -> MultiplexedMemoryError {
			return MultiplexedMemoryError(syscall_multiplexed_memory_read(
				handle, offset, u64(uintptr(dest)), size, width,
			))
		}

		syscall_multiplexed_memory_write_userspace :: proc "contextless" (
			handle, offset: u64,
			source: rawptr,
			size, width: u64,
		) -> MultiplexedMemoryError {
			return MultiplexedMemoryError(syscall_multiplexed_memory_write(
				handle, offset, u64(uintptr(source)), size, width,
			))
		}
	}
}
