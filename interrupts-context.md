INTERRUPTS + WAKEUP: CONTEXT (written 2026-10-15, updated 2026-10-18)

STATUS: DONE AND WORKING (2026-10-18). NVMe completions raise MSI-X vector 0x20, the halted core wakes, and nvme.wait returns.
- Why it was needed: with idleCount == 0 (every VM, BIOS-disabled MWAIT, probably every AMD cpu), cpu_sleep does sti; hlt with the lapic timer off. With no device interrupt, nothing ever woke the core.
- The bug that cost time: MSI_ADDRESS_BASE was typed as 0xFE0_0000 instead of 0xFEE0_0000. The MSI went out as a plain DMA write into RAM at about 254 MiB: no interrupt, and silent RAM corruption.
- Debug tip: Fedora QEMU has no `log` trace backend, so `-trace` prints nothing. Use guest-side prints, or the monitor (`-serial mon:stdio`, then Ctrl-a c: info registers -a, info lapic, xp).

DECIDED
- Kernel only does security-sensitive work; everything else is exposed to userland, foot-guns allowed.
- Wait = spin briefly in userspace (poll the CQ phase), then wait_on(word) and sleep. The interrupt is the wake source. Kernel polling only as a safety net.
- Hardware: MSI-X default, MSI fallback, no pin (INTx) interrupts, no IOAPIC (hardware-assumptions.md).
- Kernel side = minimal: every device vector (32 ..< 0xF0) only gets an EOI (kernel/idt.odin irq_handler default case). The idle loop then rechecks sleepers.
  No irq_bind syscall, no per-vector counter, no cross-core forwarding: userland picks the target core.
- Kernel-owned vectors: 0xF0 timer, 0xF1 error, 0xF2 thermal, 0xF3/0xF4 lint, 0xF5 IPI, 0xFF spurious. Devices get 32..0xEF.
- Only the trusted device owner (adam) programs MSI-X tables. Nobody gets perms on the 0xFEE00000 window, so contract HasPerm checks block forged MSI DMA.
- The kernel never migrates grants (per-cpu grants/sleepers lists), so syscalls.cpu_current_index() (rdtscp, TSC_AUX = cpu index) stays valid for the calling grant.

CODE
- lib/pci/msix.odin: CAP_ID_MSIX, MsixMessageControl, MsixCapability (layout only; fields are read one by one with ecam_read_u16/u32, never as a 12B struct), MsixTableEntry, MSIX_BAR_INDEX_MASK, MSI_ADDRESS_BASE 0xFEE0_0000.
  msix_table(device) -> ([]MsixTableEntry, capOffset, Error): .NotFound if there is no cap, .Corrupt on a bad BIR/BAR/size.
- lib/pci/pci.odin: config_read_u16/config_write_u16 are volatile (via ecam_*) with asserts. COMMAND_INTX_DISABLE bit 10. CONFIG_SPACE_SIZE 4096. DEVICE_MAX_CAPABILITIES 48 (the real max of dword-aligned caps in 0x40..0xFF). capabilities is a [dynamic; N] fixed-capacity array, no count field.
- adam/drivers.odin, NVMe case: nvme.init, defer controller_disable on failure (result != .Initialized), msix_table, row NVME_MSIX_ROW (0): addr = MSI_ADDRESS_BASE | apicId << 12 (assert apicId <= 255), data = NVME_VECTOR 0x20, vectorControl 0 last, each one a separate u32 volatile store (MSI-X table allows only 4/8B accesses).
  Then messageControl.enable = 1 and functionMask = 0, then command |= INTX_DISABLE, then queue_pair_create(dev, NVME_MSIX_ROW).
  It must run after nvme.init (which turns on COMMAND_MEMORY; table writes are dropped without it) and before I/O CQ creation.
- The admin CQ also uses row 0, so admin completions fire 0x20 as well (harmless).

OPEN
- An interrupt landing while a process runs: sleepers are only rechecked at the end of the current slice (latency = slice). Later: preempt when a woken sleeper exists.
- sleep_target stops watching grantedWeight while any sleeper exists, so new work for that cpu waits until the deadline. Fix with an IPI on cross-cpu enqueue.
- MWAIT detection: if CPUID leaf 1 ECX bit 3 (MONITOR) is set, idleCount >= 1 with hint 0x00 (C1). Deeper states from leaf 5 EDX (Intel) or ACPI _CST later.
- Kernel poll-cap safety net for sleepers with no interrupt source (drop the len > 1 condition at grant.odin:357): undecided.
- Multi-queue: each queue on its own core needs its own MSI-X row aimed at that core (queue_pair_create already takes msixRow).
- Userspace spin budget before wait_on is not implemented yet (nvme.wait sleeps right away after one poll).
- Default stack size: PE apps use SizeOfStackReserve/Commit; native programs 1 MiB for now; later grow on a guard-page fault. Freestanding has no stack probes, so a frame > 4 KiB can jump the guard page.
