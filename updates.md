# updates plan

Design lives in os-design.md. This file holds the work order.

Order: secure + parallel ifs first. Updates come only after that.

## 1. Secure + parallel ifs (first)
1. Kernel contract engine: Rule validation at create, runtime switch (contracts.md). Code written, untested.
1a. Proof tooling (model checks run the actual code, never a hand-written model):
    1. Unblock `odin test kernel` (asm_helpers cpuid_asm test stub). DONE.
    2. Race checker on lib/spinlock: hook seam on each atomic + cpu_relax (`when ODIN_TEST`), baton scheduler over real threads,
       cpu_relax = blocked until another thread writes, modelcheck extended with schedule-prefix replay, deadlock detection, parent-index traces.
       Prove: Spinlock mutual exclusion, RWLock (writers == 1 && readers == 0) || writers == 0, no deadlock, existing asserts never fire.
       Memory model SC (sound on x86 here: ordering-critical ops are locked RMWs). Expect: nested rw_read_lock + waiting writer deadlocks.
    3. Engine model check: real contract_validate + contract_run_NO_LOCK over all bounded programs. Prove validate => run returns without asserts.
    4. Contract race check: real syscall_contract_create / syscall_contract_memory_access / edit Delete in parallel. Prove no rules use-after-free, no deadlock.
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
