package firstpe

foreign import ntdll "ntdll.lib"
foreign ntdll {
	ExitProcess :: proc "c" (exitCode: u32) ---
}

@(export)
_start :: proc "c" () {
	ExitProcess(1337)
}
