1. The SSD is a PCIe device. It's a separate computer with its own chip (the controller). The CPU and the SSD talk through two channels:

2. Registers (CPU → device).

- A register is a small variable that lives inside the device's chip, not in RAM.
- The device exposes them as a range of addresses called BAR0. When the CPU does store [bar0 + 0x14], 1, it looks like a memory write, but it goes over PCIe into the chip. That's MMIO (memory-mapped I/O).
- Examples:
  - CC at 0x14: "enable yourself".
  - CSTS at 0x1C: "am I ready / did I crash".
  - ASQ/ACQ: "the admin queues are at these RAM addresses".
  - Doorbells at 0x1000+: "new work is ready" (explained below).

3. RAM (device → memory).

- The device can read and write your RAM by itself, without the CPU. That's DMA.
- All real data and all commands live in RAM. Registers only carry smal

4. Queue = a ring of fixed-size slots in RAM. There are two kinds, always paired:

- SQ (submission queue): slots of 64 bytes. You write commands here, e.ount: 1, dest RAM addr (prp1): 0x5000, cid: 7}.
- CQ (completion queue): slots of 16 bytes. The device writes results here, e.g. {cid: 7, status: ok}.
- A ring means that after the last slot you wrap to slot 0.

5. Doorbell = one register per queue.

- The device doesn't watch the SQ in RAM, so after writing commands you write the new tail index into that SQ's doorbell register ("filled up to here"). The device then fetches those slots via DMA.
- After reading completions, you write the new head index into the CQ's doorbell ("consumed up to here, you can reuse those CQ slots").

6. Knowing a completion is new: the phase bit.

- Each CQE has 1 bit that the device flips every time it wraps around the ring.
- If the bit matches what you expect, the entry is new. If not, it's old and you keep waiting.
- Optionally the device fires an interrupt (MSI-X) instead of you polling.

7. cid (command id). A 16-bit number you put in the command. The device echoes it back in the CQE, so you know which command finished. In our design the kernel stamps it: that's the token, and the CQ is the witness.

8. Admin queue vs I/O queues.

- Admin queue (queue 0): control commands like "identify yourself" and "create I/O queue #3 at RAM addr X". In our design only adam uses it.
- I/O queues (1..N): read/write commands. There can be many, so each pr

9. Disk addressing.

- LBA = block number on the disk (512B or 4KB each).
- Namespace (nsid) = a partition-like slice of the disk. We use the first one.

One full read:

1. Write the command into your SQ slot in RAM.
2. Write the new tail to your SQ doorbell register.
3. The device DMAs the command in, reads LBA 100 from flash, and DMAs t

4. You write the new head to your CQ doorbell register.

Where security comes in:

- The device trusts every number in a command. Say your command says "write to RAM 0x9000" and 0x9000 belongs to another process: the device does it anyway.
- So the kernel has to check the command's prp1 (RAM addr) and lba (disk addr) against your perms.
- Doorbell values have to be checked too (< depth), because they're num

1. Write the command into your SQ slot in RAM.
2. Write the new tail to your SQ doorbell register.
3. The device DMAs the command in, reads LBA 100 from flash, and DMAs the data to RAM 0x5000.
4. The device writes {cid 7, ok} into your CQ in RAM and flips the phase bit.
5. You see the phase bit and read the result.
6. You write the new head to your CQ doorbell register.

Where security comes in:

- The device trusts every number in a command. Say your command says "write to RAM 0x9000" and 0x9000 belongs to another process: the device does it anyway.
- So the kernel has to check the command's prp1 (RAM addr) and lba (disk addr) against your perms.
- Doorbell values have to be checked too (< depth), because they're numbers you give the device.
