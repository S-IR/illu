package ifs


read_range :: proc(dev: ^Device, offset: u64, buf: []byte) -> Error {
	return range_io(dev, .Read, offset, buf)
}
write_range :: proc(dev: ^Device, offset: u64, buf: []byte) -> Error {
	return range_io(dev, .Write, offset, buf)
}

@(private)
range_io :: proc(dev: ^Device, dir: Direction, offset: u64, buf: []byte) -> Error {
	blockSize := u64(dev.blockSize)
	if !range_valid(dev, offset, u64(len(buf))) do return IfsError.OutOfRange

	bounce: []byte = nil
	block := offset / blockSize
	inBlock := offset % blockSize
	rest := buf
	for len(rest) > 0 {
		if inBlock == 0 &&
		   u64(len(rest)) >= blockSize &&
		   uintptr(raw_data(rest)) % uintptr(blockSize) == 0 {
			device_io(dev, dir, block, rest[:blockSize]) or_return
			rest = rest[blockSize:]
		} else {
			if bounce == nil do bounce = make_aligned([]byte, dev.blockSize, int(dev.blockSize), context.temp_allocator)
			device_read(dev, block, bounce) or_return
			n: int
			switch dir {
			case .Read:
				n = copy(rest, bounce[inBlock:])
			case .Write:
				n = copy(bounce[inBlock:], rest)
				device_write(dev, block, bounce) or_return
			}
			rest = rest[n:]
			inBlock = 0

		}
		block += 1

	}
	return nil

}
range_valid :: proc(dev: ^Device, offset, size: u64) -> bool {
	diskBytes := dev.blockCount * u64(dev.blockSize)
	return offset <= diskBytes && size <= diskBytes - offset
}
