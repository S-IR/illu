package ntdi

import "../../alloc"
import "../../syscalls"
import _ "../../win64rt"
import "base:runtime"

@(export)
ExitProcess :: proc "c" (exitCode: u32) {
	syscalls.syscall_exit(u64(exitCode))
}


@(export)
GetStdHandle :: proc "c" (stdHandle: i32) -> rawptr {
	return rawptr(uintptr(1)) // sentinel "stdout" pseudo-handle
}

@(export)
WriteFile :: proc "c" (
	handle: rawptr,
	buffer: rawptr,
	bytesToWrite: u32,
	bytesWritten: ^u32,
	overlapped: rawptr,
) -> i32 {
	when ODIN_DEBUG {
		syscalls.syscall_debug_print_userspace("WriteFile", u64(uintptr(buffer)))
	}
	if bytesWritten != nil do bytesWritten^ = bytesToWrite
	return 1 // TRUE
}
@(export)
GetProcessHeap :: proc "c" () -> rawptr {
	return rawptr(uintptr(1))
}

@(export)
HeapAlloc :: proc "c" (heap: rawptr, flags: u32, size: uint) -> rawptr {
	context = runtime.default_context()
	p, err := alloc.heap_alloc(int(size), 0, true)
	if err != nil do return nil
	return p
}

@(export)
HeapFree :: proc "c" (heap: rawptr, flags: u32, mem: rawptr) -> i32 {
	context = runtime.default_context()
	alloc.heap_free(mem, 0)
	return 1
}

UNIMPLEMENTED_EXIT_CODE :: 0xDEAD0000
@(export)
unimplemented_stub :: proc "c" () {
	syscalls.syscall_exit(UNIMPLEMENTED_EXIT_CODE)
}
