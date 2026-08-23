# OS design notes

> **We design to work at memory permissions until we hit a wall. Anything else—devices, Wi‑Fi, Ethernet, drivers—is an abstraction.**

## Long-term process and module model

- There is no static-library concept. Everything is dynamically loadable.
- An executable is a library/module with a selected entry point.
- The loader treats programs and libraries through the same file/module format; the selected entry point is the distinction.
- Adam is the userspace device manager, module loader, and process launcher.
- Adam may scan a filesystem directory such as `vitals/pci` for device modules.
- A PCI module declares the devices/classes it supports and supplies an entry point.
- Adam grants device memory, interrupt, DMA, and other permissions to the spawned protection domain through syscalls.
- IOMMU configuration prevents a userspace device owner from DMA-writing memory outside its granted regions.
- Spawned programs receive explicit device/resource grants and the descriptions or handles needed to use those resources.

## PCI and driver architecture

- Adam scans every PCI function.
- Generic PCI dispatch selects a subsystem path from class/subclass information.
- A vendor driver performs matching and hardware-specific attach/setup.
- Hardware-specific code must register a generic subsystem device interface rather than exposing vendor state to the rest of the OS.
- The current statically linked dispatch is a bootstrap; it will later be replaced by dynamically loaded module registration.

## Network and Wi-Fi architecture

- Multiple physical Wi-Fi devices are supported.
- A networking service owns a dynamic collection of generic Wi-Fi/NIC device instances.
- Each driver attach creates one generic device instance and registers it in that collection.
- Each instance has stable identity/resource information and driver-private state.
- Realtek/other chipset code owns register layouts, firmware, DMA rings, and interrupt details.
- Generic networking code operates through the device interface and does not know vendor register details.
- The current statically linked bootstrap uses Odin's tagged-union driver model, following the previous project's `NIC_Impl` pattern. Generic operations switch on the concrete driver type so the compiler can see every built-in driver.
- Dynamically loaded modules will require a later module boundary/ABI; that boundary must not dictate function-pointer dispatch inside the current statically linked bootstrap.

## Update and restart model

- System and userspace updates should not require rebooting the whole machine whenever possible.
- The kernel is the least frequently replaceable component; kernel replacement is a separate, harder problem.
- Adam, device drivers, filesystem libraries, and applications should have restartable process boundaries.
- A driver update should quiesce its device, stop DMA and interrupts, preserve or transfer generic service state, load the new implementation, and reattach the device.
- User-visible state such as sockets and routes should live in the owning library OS above replaceable hardware drivers where practical.
- Updates need explicit handoff and versioning rules so state can transfer between old and new processes.
- Static linking is acceptable for the bootstrap and does not imply a whole-system restart; it only means the containing userspace process must be replaced when that component changes.

## Generic resource permissions

- The kernel does not need a device-specific ownership model.
- Hardware access is represented through generic capabilities:
  - page mappings for PCI configuration and MMIO ranges;
  - multiplexed-memory handles for shared physical ranges;
  - DMA/IOMMU mappings for process-owned buffers;
  - interrupt/event capabilities for completion notifications.
- Direct access is granted by mapping the relevant pages.
- Shared access is granted by a multiplexed-memory handle that serializes operations on a physical range.
- If hardware exposes isolated VFs or other partitions, their pages, DMA mappings, and interrupts are simply granted as separate resources.
- The kernel revokes mappings, interrupts, and DMA permissions when a protection domain exits.

## Multiplexed memory capabilities

- Any eligible physical/shared memory range may be exposed through a generic multiplexed-memory capability rather than direct mappings.
- The kernel owns the physical range and serializes access from multiple processes.
- Creating the capability returns a handle, not a staging pointer.
- Read/write syscalls accept any caller-supplied pointer the caller already owns; the kernel validates the complete pointer range, its length, and its permissions before using it.
- The submitted buffer boundary must match the multiplexed range or requested operation boundary, according to the capability contract.
- The kernel validates source/destination memory, range bounds, access permissions, access width, and ordering before touching the target range.
- The mechanism is device-agnostic; userland libraries interpret the register meanings.
- Direct mappings remain available for exclusive resource owners.
- DMA buffers remain separately granted through paging and IOMMU permissions.
- This is a general memory mechanism; devices are only one possible use.
