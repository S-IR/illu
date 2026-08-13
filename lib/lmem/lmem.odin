package lmem


PageSize :: enum {
	_4KB,
	_2MB,
	_1GB,
}
PageFlag :: enum u64 {
	Present = 0,
	Write   = 1,
	User    = 2,
	PWT     = 3,
	PCD     = 4,
	PS      = 7,
	NX      = 63,
}
PageFlags :: bit_set[PageFlag;u64]
#assert(size_of(PageFlags) == size_of(u64))
