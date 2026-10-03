package ifs

import "core:testing"

TEST_BLOCK_SIZE :: 512
TEST_BLOCK_COUNT :: 64
TEST_DISK_BYTES :: TEST_BLOCK_SIZE * TEST_BLOCK_COUNT

@(test)
test_detect_blank :: proc(t: ^testing.T) {
	bytes: [TEST_DISK_BYTES]byte
	disk := RamDisk{bytes[:]}
	dev := Device {
		backend    = &disk,
		blockSize  = TEST_BLOCK_SIZE,
		blockCount = TEST_BLOCK_COUNT,
	}

	_, found, err := detect(&dev)
	testing.expect(t, err == nil)
	testing.expect(t, !found)

}
