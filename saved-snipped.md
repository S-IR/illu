device.odin:
odin
package ifs
import "../nvme"

IfsError :: enum {
None,
OutOfRange,
DiskFull,
Corrupt,
OutOfMemory,
}

Error :: union #shared_nil {
IfsError,
nvme.IoError,

Backend :: union #no_nil {
^RamDisk,
^nvme.Queue,
}

Device :: struct {
backend: Backend,
blockCount: u64,
blockSize: u32,
}

DevicePending :: union {
nvme.Pending,
assert(len(buf) == int(dev.blockSize))
assert(block < dev.blockCount)
switch backend in dev.backend {
case ^nvme.Queue:
assert(backend.lbaSize == dev.blockSize)
p, ioErr := nvme.queue_io(backend, op, block, buf)
return p, ioErr
case ^RamDisk:
disk := ram_block(dev, backend, block)
if op == .Read {
copy(buf, disk)
} else {
copy(disk, buf)
}
}
return nil, nil
}

device_wait :: proc(pending: DevicePending) -> Error {
switch p in pending {
case nvme.Pending:
return nvme.wait(p)
}
return nil
}

@(private)
ram_block :: proc(dev: ^Device, disk: ^RamDisk, block: u64) -> []u8 {
assert(u64(len(disk.bytes)) == dev.blockCount * u64(dev.blockSize))
return disk.bytes[block * u64(dev.blockSize):][:dev.blockSize]
}

io.odin, the whole file:
odin
package ifs
import "../nvme"

read_range :: proc(dev: ^Device, offset: u64, buf: []byte) -> Error {
return range_io(dev, .Read, offset, buf)
}

write_range :: proc(dev: ^Device, offset: u64, buf: []byte) -> Error {
return range_io(dev, .Write, offset, buf)
}

@(private)
range_io :: proc(dev: ^Device, op: nvme.IoOpcode, offset: u64, buf: []byte) -> Error {
assert(op == .Read || op == .Write)
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
                      pending := device_submit(dev, op, block, rest[:blockSize]) or_return
                      device_wait(pending) or_return
                      rest = rest[blockSize:]
              } else {
                      if bounce == nil do bounce = make_aligned([]byte, dev.blockSize, int(dev.blockSize), context.temp_allocator)
                      pending := device_submit(dev, .Read, block, bounce) or_return
                      device_wait(pending) or_return
                      n: int
                      if op == .Read {
                              n = copy(rest, bounce[inBlock:])
                      } else {
                              n = copy(bounce[inBlock:], rest)
                              pending = device_submit(dev, .Write, block, bounce) or_return
                              device_wait(pending) or_return
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
