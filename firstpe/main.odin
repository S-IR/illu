package firstpe

foreign import ntdll "ntdll.lib"
foreign ntdll {
	ExitProcess :: proc "c" (exitCode: u32) ---
	GetProcessHeap :: proc "c" () -> rawptr ---
	HeapAlloc :: proc "c" (heap: rawptr, flags: u32, size: uint) -> rawptr ---
	HeapFree :: proc "c" (heap: rawptr, flags: u32, mem: rawptr) -> i32 ---
}

foreign _ {
	gs_read_u64 :: proc "c" (offset: u64) -> u64 ---
}

@(export)
_start :: proc "c" () {
	tebSelf := gs_read_u64(0x30)
	pebPtr := gs_read_u64(0x60)
	selfCheck := (^u64)(rawptr(uintptr(tebSelf + 0x30)))^
	imageBase := (^u64)(rawptr(uintptr(pebPtr + 0x10)))^

	heap := GetProcessHeap()
	p := HeapAlloc(heap, 0, 64)

	writeOk := false
	if p != nil {
		bytes := (^[64]u8)(p)
		for i in 0 ..< 64 do bytes[i] = u8(i)
		writeOk = true
		for i in 0 ..< 64 do if bytes[i] != u8(i) do writeOk = false
	}

	freed := i32(0)
	if p != nil do freed = HeapFree(heap, 0, p)

	code: u32 = 0
	if tebSelf != 0 && tebSelf == selfCheck do code |= 1
	if pebPtr != 0 do code |= 2
	if imageBase != 0 do code |= 4
	if p != nil do code |= 8
	if writeOk do code |= 16
	if freed != 0 do code |= 32

	ExitProcess(code)
}
