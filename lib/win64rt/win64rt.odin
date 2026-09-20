package win64rt

// Symbols the Odin runtime and lld-link expect to exist under
// -target:freestanding_amd64_win64, normally supplied by a real Windows CRT.
// There is no CRT here -- any package built for that target should blank-
// import this package (`import _ "../win64rt"`, path relative to caller) so
// the linker finds them.

// @(export) is required here for cross-object linkage under this target
// (without it, lld-link reports these as undefined -- tested), and on
// win64/-dll builds Odin's @(export) also emits a PE export-directory
// entry as a side effect. That means these CRT-glue symbols show up in
// ntdll_immitator.dll's export table alongside the real ntdll functions.
// Harmless (nothing will ever import "_fltused"/"memset" by name from a
// real app) but not clean -- left as a known cosmetic wart; suppressing
// it needs either a linker-level exclude (lld-link doesn't expose one) or
// hand-written asm for these four symbols instead of Odin @(export) procs.
@(export, link_name = "_fltused")
_fltused: i32 = 1

@(export, link_name = "_tls_index")
_tls_index: u32 = 0

@(export, link_name = "memset")
mset :: proc "c" (ptr: rawptr, val: i32, #any_int len: uint) -> rawptr {
	d := ([^]u8)(ptr)
	for i in 0 ..< len do d[i] = u8(val)
	return ptr
}

@(export, link_name = "memmove")
mmove :: proc "c" (dst, src: rawptr, #any_int len: uint) -> rawptr {
	d := ([^]u8)(dst)
	s := ([^]u8)(src)
	if uintptr(dst) < uintptr(src) {
		for i in 0 ..< len do d[i] = s[i]
	} else {
		for i := len; i > 0; i -= 1 do d[i - 1] = s[i - 1]
	}
	return dst
}

@(export, link_name = "memcpy")
mcpy :: proc "c" (dst, src: rawptr, #any_int len: uint) -> rawptr {
	d := ([^]u8)(dst)
	s := ([^]u8)(src)
	for i in 0 ..< len do d[i] = s[i]
	return dst
}
