HARDWARE ASSUMPTIONS WE CAN MAKE

CPU
Invariant TSC (constant rate, runs in sleep states). TSC-deadline LAPIC timer. Single socket (TSC deadlines compared across cores).

RAM
DDR3 or newer, physically contiguous above 1 MB from EFI memory map.

At least 2 GB total system memory (Windows 10 minimum is 2 GB, so we assume that).

EFI memory map provides usable pages; we can allocate physically contiguous DMA buffers.

Interrupts
MSI-X default, MSI fallback. No pin (INTx) interrupts, no IOAPIC routing. Every device we support has MSI or MSI-X.

Disk
At least one NVMe 1.0+ drive (PCIe M.2/U.2). 15-year-old hardware puts us around 2011; NVMe started shipping in consumer hardware ~2013 (Samsung XP941), so this is aggressive but okay if we allow SATA fallback. For simplicity we can assume NVMe, but if we need 15-year coverage, we must also handle AHCI/SATA.

If NVMe: MSI-X, at least 2 I/O queue pairs (admin + 1 I/O queue pair minimum; ideally 64 to give many processes their own queue).

If AHCI/SATA: 1–4 ports, NCQ, 48-bit LBA, MSI or MSI-X interrupts.

LBA size 512 bytes or 4096 bytes (both handled).

Network
Real consumer NICs: Realtek RTL8111/8168 (most common wired NIC on consumer boards, dev laptop has it) and Intel I219 (e1000e family, Intel laptops). Plain e1000 (82540, QEMU default) is out: pins only, no MSI.

Wi-Fi: Intel CNVi (iwlwifi family, dev laptop 8086:7a70).

MSI-X (preferred) or MSI.

1 Gbps line rate.

At least 32 TX/RX descriptors per ring.

Graphics
Boot/fallback: UEFI GOP framebuffer – linear framebuffer, typically BGRA 32-bit, resolution at least 1024x768.


FS REQS

GOALS

- fs behaves like memory. protection like RAM perms, not a separate ACL system.
- many untrusted apps share storage, no daemon mediator.
- minimal kernel involvement per op.
- parallel by default.
- fast header lookup.

RESEARCH CONSTRAINTS BACKING THE GOALS ABOVE

- metadata ops dominate call volume - 50%+ of fs calls are open/stat/close, not read/write.
- most files are write-once-then-read-many (bimodal). true concurrent read-write on one file
  is rare.
- ~50% of files on a real machine are <2KB (measured on this machine: 166640/342860 files
  under 2048 bytes).
- fragmentation matters a lot for HDD (seek cost), barely matters for SSD/NVMe (no seek
  penalty, controller parallelism doesn't care about extent count) except for header size and
  allocator behavior.
- no meaningful OS-imposed cap on total files/dirs per volume (ext4 ~4B inodes, NTFS ~4.29B
  MFT records) - can't size anything statically assuming a small ceiling.
