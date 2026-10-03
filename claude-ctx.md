# claude session context

## workflow
- user hand-types code printed in chat, one small step per reply, review each paste. "you change it" -> edit directly + check:
  - adam: `odin check adam -no-entry-point -target:freestanding_amd64_sysv -vet-shadowing`
  - kernel: `odin check kernel -no-entry-point -target:freestanding_amd64_sysv -vet-shadowing -define:KERNEL_BUILD=true`
- design talk: one recommendation, plain words, no jargon surveys. only the user's explicit choices are decisions.
- lock + unlock must sit next to each other: `{ lock; defer unlock; ... }` scopes.
- goal: working fs in adam, SECURITY IGNORED for now (adam has full nvme access).
- user's cpu: i5-8300H (no UMWAIT/WAITPKG, no user mwait). qemu `-cpu host,+invtsc`.

## STOPPED HERE (2026-10-03)
pending snippets the user saved in saved-snipped.md (NOT on disk yet):
- lib/ifs/device.odin: dead types removed (DiskTooSmall, DirFull, BlockError, DeviceError, Direction, device_read/write/io).
  `Error :: union #shared_nil {IfsError, nvme.IoError}`, `DevicePending :: union {nvme.Pending}`,
  device_submit(dev, op: nvme.IoOpcode, block, buf) -> (DevicePending, Error) (ramdisk finishes inline, pending nil), device_wait(pending).
- lib/ifs/io.odin: range_io(dev, op: nvme.IoOpcode, ...) uses submit+wait per block (same behavior as before).
NEXT:
1. range_io: submit all blocks then wait once (QueueFull -> wait oldest, retry).
2. pathmap scan rewrite (printed earlier, paused until async io existed): level by level, read_files = submit all files of a level, wait once.
   keeps ALL files in the map (adam holds the full table). collects used extents for the allocator. dir = [SlotCount u64][slots], slot 0 = name file.
3. mount.odin init: found -> scan -> disk_allocator_init(used); not found -> disk_allocator_init({{0,1}}) + format. (user mid-edit on disk.)
4. boot test WaitOn: does the ssd's DMA write wake MONITOR? (unverified)

## ifs layout (decided)
- Slot {offset, cap u64}: cap = bytes owned on disk (whole blocks). zero slot = free.
- dir = [SlotCount u64][slots], slot 0 = per-dir name file. file type (dir = ends with '/') decided by NAME only, no flags.
- name file = [HeaderOfNameEntry{slotIdx, nameLen u64}][name][pad8]..., slotIdx 0 = end, nameLen 0 = deleted, rename rewrites the name file.
- create = slot first then name. delete = name first then slot.
- superblock {magic, root: Slot} in block 0, written last by format.
- allocator: lib/ifs/alloc.odin, adam only, block units. sorted-by-block [dynamic]Extent{block,count}, disk_alloc first fit, disk_free binary_search_by + 4-case merge,
  disk_allocator_init(alloc, blockCount, used) builds free list from gaps. granter hands other processes whole blocks.

## async io (on disk)
- lib/nvme/io.odin: Queue.states[QUEUE_DEPTH_MAX=64] per command id, queue_submit -> Pending{queue,cid}, queue_poll files completions by cid,
  wait(p, timeout) polls then sleeps via WaitOn on the next cq slot's u64 at offset 8 (phase check before sleeping), queue_io, queue_io_sync = queue_io + wait.
  every Pending must be waited (frees the cid). one user per queue.
- WaitOn syscall (= 6): `syscall_wait_on_userspace(addr: ^u64, oldValue, deadline) -> WaitOnError{None, TimedOut, InvalidAddress, InvalidSaveArea}`.
  sleeps while *addr == oldValue (futex style), deadline = tsc. ODIN_TEST stub returns .None.
  kernel saves user state itself into grant.saveArea (syscall_entry pushes rbx,rbp,r12-r15 = SyscallFrame; save_area_xsave asm shared with preempt).
- kernel/grant.odin: cpu.sleepers [dynamic]SleepingGrant{using grant, using wait: WaitTarget}. grant_loop = grant_pop (wake sleepers, pop) -> grant_run, else cpu_sleep
  (MONITOR first sleeper addr or grantedWeight, lapic_set_deadline_at earliest deadline, >1 sleeper also polls every 100us). running grant + sleepers -> slice armed.
  grant_switch_out(cpu, Maybe(WaitTarget)) shared by preempt + sleep. wake clamps virtualTime to floor.
- CpuInfo.grantedWeight (renamed from runnableWeight) = sum of granted weights, NOT changed by sleep/wake.
- save area control word stays growable for future user flags (only `restoring` + xsaveMask today).

## parked
- watch/notify cross-process design (Watch/Unwatch/Notify registry, notify = atomic add on counters): needs renumbering after WaitOn=6, listeners sleep via WaitOn.
- security: transfer_perm, fault upcall, granter, mediated memory (fs-design.md top half). pathmap scan aborts on one corrupt dir; corrupt dir cycles loop forever.
- interrupts to processes: only if spinning/WaitOn isn't enough.
- sleep charges a full slice (no per-use accounting).
- log sink (drivers.odin drops the Error to `.Failed, 0`). nvme queue ids never reused; no flush. AMD tsc-deadline unverified.
