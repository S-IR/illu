
HARDWARE ASSUMPTIONS WE CAN MAKE 

RAM
DDR3 or newer, physically contiguous above 1 MB from EFI memory map.

At least 2 GB total system memory (Windows 10 minimum is 2 GB, so we assume that).

EFI memory map provides usable pages; we can allocate physically contiguous DMA buffers.

Disk
At least one NVMe 1.0+ drive (PCIe M.2/U.2). 15-year-old hardware puts us around 2011; NVMe started shipping in consumer hardware ~2013 (Samsung XP941), so this is aggressive but okay if we allow SATA fallback. For simplicity we can assume NVMe, but if we need 15-year coverage, we must also handle AHCI/SATA.

If NVMe: MSI-X, at least 2 I/O queue pairs (admin + 1 I/O queue pair minimum; ideally 64 to give many processes their own queue).

If AHCI/SATA: 1–4 ports, NCQ, 48-bit LBA, MSI or MSI-X interrupts.

LBA size 512 bytes or 4096 bytes (both handled).

Network
At least one Intel e1000/e1000e NIC (PCIe or onboard). These are ubiquitous in enterprise and consumer boards from ~2008 onward.

MSI-X (preferred) or MSI for TX/RX interrupt routing.

1 Gbps line rate.

At least 32 TX/RX descriptors per ring.

Graphics
Boot/fallback: UEFI GOP framebuffer – linear framebuffer, typically BGRA 32-bit, resolution at least 1024x768.
