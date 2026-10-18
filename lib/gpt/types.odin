package gpt


SIGNATURE :: u64(0x5452_4150_2049_4645) // "EFI PART"
HEADER_BLOCK_LOCATION :: 1
Guid :: [16]u8

Header :: struct #packed {
	signature:                u64,
	revision:                 u32, // 0x0001_0000
	headerSize:               u32, // >= 92, <= block size
	headerCrc32:              u32, // crc32 of header[:headerSize] with this field = 0
	reserved:                 u32, // must be 0
	myLba:                    u64, // 1 for primary
	alternateLba:             u64, // backup header LBA
	firstUsableLba:           u64,
	lastUsableLba:            u64, // inclusive
	diskGuid:                 Guid,
	partitionEntryLba:        u64, // usually 2
	partitionEntryCount:      u32, // usually 128
	partitionEntrySize:       u32, // 128 * 2^n
	partitionEntryArrayCrc32: u32, // crc32 of count*size bytes
}
#assert(size_of(Header) == 92)
#assert(offset_of(Header, headerCrc32) == 16)
#assert(offset_of(Header, diskGuid) == 56)
#assert(offset_of(Header, partitionEntryLba) == 72)
#assert(offset_of(Header, partitionEntryArrayCrc32) == 88)

PartitionEntry :: struct #packed {
	typeGuid:   Guid, // all zero = unused
	uniqueGuid: Guid,
	firstLba:   u64,
	lastLba:    u64, // inclusive
	attributes: u64,
	name:       [36]u16, // UTF-16LE
}
#assert(size_of(PartitionEntry) == 128)
#assert(offset_of(PartitionEntry, firstLba) == 32)
#assert(offset_of(PartitionEntry, name) == 56)

TYPE_EFI_SYSTEM :: Guid {
	0x28,
	0x73,
	0x2a,
	0xc1,
	0x1f,
	0xf8,
	0xd2,
	0x11,
	0xba,
	0x4b,
	0x00,
	0xa0,
	0xc9,
	0x3e,
	0xc9,
	0x3b,
} // C12A7328-F81F-11D2-BA4B-00A0C93EC93B
TYPE_MS_BASIC_DATA :: Guid {
	0xa2,
	0xa0,
	0xd0,
	0xeb,
	0xe5,
	0xb9,
	0x33,
	0x44,
	0x87,
	0xc0,
	0x68,
	0xb6,
	0xb7,
	0x26,
	0x99,
	0xc7,
} // EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, ntfs/fat
TYPE_LINUX_FS :: Guid {
	0xaf,
	0x3d,
	0xc6,
	0x0f,
	0x83,
	0x84,
	0x72,
	0x47,
	0x8e,
	0x79,
	0x3d,
	0x69,
	0xd8,
	0x47,
	0x7d,
	0xe4,
} // 0FC63DAF-8483-4772-8E79-3D69D8477DE4, ext4

Partition :: struct {
	typeGuid:          Guid,
	firstLba, lastLba: u64,
}
MetaBlock :: enum {
	Mbr,
	PrimaryHeader,
	BackupHeader,
}
