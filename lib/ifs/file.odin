package ifs
Slot :: struct {
	offset, cap: u64,
}
#assert(size_of(Slot) == 16)
DirHeader :: struct {
	count, reserved: u64,
}
#assert(size_of(DirHeader) == 16)

NameFileHeader :: struct {
	refLen, heapOffset: u64,
}
#assert(size_of(NameFileHeader) == 16)
