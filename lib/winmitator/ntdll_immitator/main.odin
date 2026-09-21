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

@(export)
RtlMoveMemory :: proc "c" (dst: rawptr, src: rawptr, n: uint) {
	d := ([^]u8)(dst)
	s := ([^]u8)(src)
	if uintptr(dst) < uintptr(src) {
		for i in 0 ..< n do d[i] = s[i]
	} else {
		for i := n; i > 0; i -= 1 do d[i - 1] = s[i - 1]
	}
}

@(export)
RtlCopyMemory :: proc "c" (dst: rawptr, src: rawptr, n: uint) {
	RtlMoveMemory(dst, src, n)
}

@(export)
RtlZeroMemory :: proc "c" (dst: rawptr, n: uint) {
	d := ([^]u8)(dst)
	for i in 0 ..< n do d[i] = 0
}

@(export)
RtlAllocateHeap :: proc "c" (heap: rawptr, flags: u32, size: uint) -> rawptr {
	return HeapAlloc(heap, flags, size)
}

@(export)
RtlFreeHeap :: proc "c" (heap: rawptr, flags: u32, mem: rawptr) -> i32 {
	return HeapFree(heap, flags, mem)
}

@(export)
RtlExitUserProcess :: proc "c" (exitCode: u32) {
	syscalls.syscall_exit(u64(exitCode))
}

@(export)
strlen :: proc "c" (s: cstring) -> uint {
	return uint(len(s))
}

@(export)
strcpy :: proc "c" (dst: cstring, src: cstring) -> cstring {
	n := uint(len(src)) + 1
	RtlMoveMemory(rawptr(dst), rawptr(src), n)
	return dst
}

@(export)
strcmp :: proc "c" (a: cstring, b: cstring) -> i32 {
	sa, sb := string(a), string(b)
	if sa < sb do return -1
	if sa > sb do return 1
	return 0
}

UNIMPLEMENTED_EXIT_CODE :: 0xDEAD0000
@(export)
unimplemented_stub :: proc "c" () {
	syscalls.syscall_exit(UNIMPLEMENTED_EXIT_CODE)
}
