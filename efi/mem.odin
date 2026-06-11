package efi

import _ "../lib/kmem"

@(export, link_name = "_fltused")
_fltused: i32 = 1

@(export, link_name = "_tls_index")
_tls_index: u32 = 0

@(export)
memset_u64 :: proc "c" (dest: rawptr, c: u8, n: u64) -> rawptr {
	d := ([^]u8)(dest)
	for i in 0 ..< n do d[i] = c
	return dest
}
