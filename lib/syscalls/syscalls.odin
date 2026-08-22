package syscalls
import "../lmem"

Syscall :: enum {
	Exit,
	MMap,
	MFree,
	InterruptVectorGet,
}

Error :: enum u64 {
	None,
	MMapInvalidPageSize,
	MMapOutOfMemory,
	MMapInvalidSize,
	MMapTrackingFailed,
	MFreeInvalidAddress,
	MFreeInvalidSize,
	InterruptNoPermission,
	InterruptNoVectors,
}

KERNEL_BUILD :: #config(KERNEL_BUILD, false)


when !ODIN_TEST {
	when !KERNEL_BUILD {
		@(default_calling_convention = "c")
		foreign _ {
			syscall_exit :: proc(code: u64) -> ! ---
			syscall_mmap :: proc(count: u64, size: u64, flags: u64) -> (err: u64, addr: u64) ---
			syscall_mfree :: proc(addr: u64) -> (err: u64) ---
			syscall_interrupt_vector_get :: proc(pci_addr: u64) -> (err: u64, vector: u64) ---
		}

		syscall_mmap_userspace :: proc "contextless" (
			count: u64,
			size: lmem.PageSize,
			flags: lmem.PageFlags,
		) -> (
			err: Error,
			addr: rawptr,
		) {
			rawErr, rawAddr := syscall_mmap(count, u64(size), transmute(u64)flags)
			return Error(rawErr), rawptr(uintptr(rawAddr))
		}

		syscall_mfree_userspace :: proc "contextless" (addr: u64) -> (err: Error) {
			return Error(syscall_mfree(addr))
		}

		syscall_interrupt_vector_get_userspace :: proc "contextless" (
			pci_addr: u64,
		) -> (err: Error, vector: u8) {
			rawErr, rawVector := syscall_interrupt_vector_get(pci_addr)
			return Error(rawErr), u8(rawVector)
		}
	}
}
