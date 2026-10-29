# updates plan

Design lives in os-design.md. This file holds the work order.

Order: secure + parallel ifs first. Updates come only after that.

## 1. Secure + parallel ifs (first)
1. Kernel contract engine: Rule validation at create, runtime switch (contracts.md). Code written.
2. Kernel ring attach point: ring_create / ring_submit / ring_reap. The kernel owns slots, tail, slot states, doorbells, and CQ reads. CqPhase completion only.
3. Pins: pinCount on MemoryResource, `.Busy` on edits, a zombie list on domain destroy.
4. Adam writes the nvme contract: allowed opcodes, disk range from perms, PRP checks.
5. Per-program nvme SQ/CQ pair guarded by the contract. Parallel: no shared queue, no lock.
6. Disk perms as a fake phys window (`DISK_BASE | diskId<<44 | lba<<bs`). Adam mounts, then grants per-file extents to programs.
7. ProtDomainEdit Transfer + the disk pool domain (os-design.md). ifs disk_alloc moves onto it.

## 2. Updates (after 1)
1. Load code from files: adam loads a lib/program blob from disk and runs it. Drivers move out of adam into separate blobs.
2. Bootloader fs readers: reads raw blocks through UEFI BlockIo, runs our read-only fs lib code (ifs first, ntfs etc later) on every partition, finds the system folder.
3. A/B manifest + `/code/<hash>` store + an updater program (write blobs, flush, write the older manifest with seq + 1, flush).
4. Bootloader picks the manifest and loads the kernel + adam + boot libs from it.
5. Each program's globals in one versioned state struct, adam first.
6. Lib hot swap at a point the program picks. Adam handoff.

Later goal: zero-downtime kernel swap (os-design.md).
