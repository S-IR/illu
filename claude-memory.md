# claude memory (terse)

## Work rules (user)

- Never invent limits or design and present them as fact. Facts: cite file:line or spec. Proposals: label them, the user decides.
- Context = files in the working tree only. Read git history only when the user asks.
- Don't flip-flop. Pick one recommendation and keep it unless the user changes it.
- Default: step-by-step pseudocode, user writes code. Write files only when explicitly asked. No comments in code.
- Keep answers SHORT (user begs). Explain with concrete trace tables.
- Check plan lines against the design's purpose before building on them.
- APIs are batched + async by default, never block. Sync helpers only as wrappers over the async API.
- err is always the LAST return value. Exception: syscall_dispatch / raw foreign decls keep err first (rax). All syscall_* + *_userspace wrappers comply (2026-10-31).
- Error returned = other outputs garbage. Exceptions allowed when they make sense.
- Never boot qemu. The user runs `.zed/debug.sh` / `.zed/prod.sh`. Build with `odin run . -debug` at most.
- _NO_LOCK fns take no locks at all; the syscall takes every lock up front. Never nest domain read locks (writer bit between = deadlock).
- To debug: get data first (prints), then hunt the bug.

## Kernel facts

- Mutable kernel state = `kernelState: KernelState` (kernel/kernel-state.odin): pmm, heap, protDomainPool, pcidAllocator, tlbGenCounter, ringPool, cpus. Boot-only globals (cpuid flags, idt, gdts, kernelPML4, directMapBase, entryRegionNext) stay loose.
- pmm is pure: every proc takes `p: ^PMM` (freeLists + earlyAllocNextPage inside PMM). lib/alloc holds no globals: `Heap{freeList, lock, pmm}` passed via `heap_allocator(&heap)` -> Allocator.data. Owners: kernelState.heap, adam `adamHeap`, ntdll_immitator `processHeap`.

- All syscall errors = shared.Error (SYSCALL range 0x400). DebugPrint prints label + value.
- Locks take `guards: [][]u8`, same g for lock and unlock. Helpers with @(deferred_out): domain_read/write_lock, domain_guards (kernel/protdomain.odin), ring_pool_read/write_lock, ring_lock (kernel/ring.odin). protDomainPool and cpu guards are still inline.
- MemoryResource: #soa kept (bench lib/soabench). Rules in `contract: ^ContractRules{r, w}`.
- user_copy_in/out(_NO_LOCK), user_mapped_range_accessible_NO_LOCK in kernel/protdomain-resources.odin.
- syscall_wait_on(addr, oldValue, deadline) kernel/grant.odin:487: futex-like, needs R on 8-aligned u64. If the cpu can't mwait (idleCount == 0, e.g. KVM), sleep_target polls sleepers every tscTicksPerMs / SLEEPER_POLLS_PER_MS.
- Contracts: kernel/contracts.odin (syscall_contract_create, syscall_contract_memory_access, contract_validate, contract_run_NO_LOCK). Design in contracts.md.

## Ring (kernel/ring.odin, lib/syscalls/ring.odin) — v1 done, tested on real nvme

Purpose: ONE ring SHARED by mutually untrusted programs; kernel mediation makes it safe. Adam makes queue pairs + rings (policy, userland).
v1: nvme only, TailDoorbell + CqPhase, no pins / Copy / List.

- create: depths 2..65536, sq.entrySize <= 64, fields fit, doorbells %4, domainCap 1..depth-1, cq.phys/entrySize %8, SQ/CQ/doorbell ranges disjoint. Caller W on authority byte + the 4 ranges (underlay increment each). cqPhase starts 1 (CQ zeroed).
- Lock order: ringPool -> caller domain -> ring. Handle = pool index; resolve checks W on authority byte.
- Slots: token = index into slots{owner, Free/InFlight/Done, status} + free-token stack. Full if inFlight == depth-1 || no free token || caller owns domainCap.
- submit: n <= depth; per entry copy in, contract, stamp token, write SQ; one fence + doorbell. accepted > 0 -> .None.
- reap: ring_cq_drain_NO_LOCK, then per token RingReapEntry{status, done}; RingWait{addr, old} (addr 0 = drain hit cap, reap again).
- destroy: pool WRITE lock, drain, inFlight > 0 -> .Busy, reserve-then-unlink, release underlays.
- ring_domain_orphan(pd) in protdomain_free: frees Done, owner = nil on InFlight.
- Decided: anyone with W on SQ memory/doorbell bypasses the contract = adam's problem for v1 (pins later).

## Throwaway ring tests (passed debug + prod 2026-10-30, marked THROWAWAY, user decides later)

- adam/ringtest.odin (fake device), adam/ringtest-nvme.odin + firstpe/ringtest.odin (real nvme, firstpe client, exported `ringTestParams` handoff). Called from adam_start.
- firstpe builds only in debug; prod embeds the last debug firstpe.exe.

## Next (user's order, 2026-10-31)

NEXT STEP: step 2 (lib/nvme queue_io / wait through rings). Step 1 verified debug 2026-10-31 (all ringtest asserts pass), prod passed too. B6 verified by user debug.sh 2026-10-31 (ring test ok + ring nvme test ok).

1. nvme parallelism: updates.md 1.3-1.6 (pins, adam nvme contract, shared SQ/CQ pairs via rings, disk perm window). Now in step 1.
   - Order (user OK 2026-10-31): 1 adam per-core rings, 2 lib/nvme through rings, 3 disk perm window (disk perms = mem perms adam grants), 4 pins, 5 Copy/List.
   - Decided 2026-10-31: public lib/nvme `queue_io` / `wait` go through ring_submit / ring_reap by default. Raw SQ path only as separate adam-only fns.
   - Step 1 defaults taken: whole-disk LBA range [0, blockCount) until step 3, temp exported params handoff, contract in lib/nvme, adam's own IO goes through a ring too (step 2).
   - Step 1 done so far: lib/nvme/contract.odin (contract_rules incl. Flush path, ring_desc), queue_pair_destroy, SQ/CQ via syscall_mmap (2 regions), Device.usedQids bit_array (qid reuse), diskhelpers NvmeRing{handle, info, cqBytes} / NvmeRings{authority, v} inside NvmeDisk, adam/nvme-rings.odin nvme_rings_destroy. syscall_mmap(_userspace) now returns (addr, err). 
   - Decided 2026-10-31: NvmeRings.v = []NvmeRing, len = len(cpu_infos), v[i] = cpu i's ring (online or not). Queues exhausted -> rest zeroed (empty = info.sq == nil; handle 0 is a valid handle); mapping cpu -> other ring is userland lib logic, not in the struct. Grant: nvme_rings_grant(rings, child, slots: []u64), len(slots) == len(v), slots[i] = cap on cpu i's ring (0 = none), gives W on [base_i, base_i+slots[i]) + R on CQ i. Partial grant on error allowed (err = inputs garbage).
   - 2026-10-31 Claude wrote (user asked): nvme ringtest rewritten on disk rings + nvme_rings_grant (cap 1 -> RingFull, other cpu ring -> NoPermission, deniedLba = blockCount, B5 on unmapped authority byte + CQ write Denied), adam memory_access_test (mapped W page, OutOfBounds, NotOwned). Passed debug 2026-10-31.
   - Done 2026-10-31 (Claude, user asked): syscall_mmap keeps caller .Present (masks {.Present, .Write, .NX, .PWT, .PCD}, adds .User + maps only if .Present). Callers pass .Present (nvme init SQ/CQ, pe-load image + 4 child pages; alloc backend + pe private regions already did). Ring authority mmap = unmapped, flags {.Write} (NX would block grant: region_flags_grantable forbids dropping NX). Passed debug 2026-10-31.
   - Step 1 done (create in drivers.odin, nvme_rings_grant, test). Open: nvme.device_destroy for the leak when adam_dispatch_pci_device fails after nvme.init (admin pages + usedQids); dead imports (nvme-regs.odin x3, init.odin alloc).
   - Detour (user 2026-10-31): unmapped byte-granular resources. MemoryResource without .Present = never mapped, any size, logical == phys, .Write = W, contract nil. Callers set .Present explicitly; kernel adds .User only to .Present regions. user_mapped_range_accessible = old check; user_range_accessible = no .Present needed, rejects contracted (used for domain + ring authority checks only). HasPermR/W stays mapped-only. Kernel only where security needs it.
     - Done: B1 rename, B2 callers set .Present, B3 Add/Delete/create gating, B4 user_range_accessible + 4 authority call sites, B6 ring per-domain slot cap (RingDesc.authoritySize 1..depth-1 replaces domainCap; cap = COUNT of authority bytes caller covers with W via user_range_covered_NO_LOCK, not specific slots; submit full when owned >= cap). nvme_rings_create done: authority = rings back to back, ring i at i*(depth-1). Verified debug 2026-10-31.
     - Done: B5 ContractMemoryAccess no-contract = plain kernel copy (R = resource exists, W = .Write). proof-design.md S5 updated.
2. Then talk with user. Goal: working os with net, gpu, keyboard, mouse, disk, screen libs.
3. Proof: PARKED in proof-design.md until the os works.

Notes:
- Build: `odin run . -debug` (also rebuilds firstpe.exe). Tests like build.odin run_tests: `odin test kernel/pmm -debug`, `odin test kernel -debug -define:KERNEL_BUILD=true`.

## Later

- Adam per core: nvme queue pair + ring with the nvme contract, grant clients W on authority + R on CQ.
- nvme contract (contracts.md "nvme"): disk range via DISK_BASE perm window (updates.md 1.6), PRP lists need Copy/List.
- lib/nvme client path through the ring (lib/nvme/io.odin).
- Pins (updates.md 1.3) must cover PRP targets (os-design.md DMA safety). Perf: submit's O(depth) `owned` scan -> per-owner count (measure first).

## Open (undecided)

- How programs get device access: see os-design.md Undecided (spawn table + ask-the-delegator proposal there).
- contracts.md says "caller owns with W"; now W only needed for wRules.
- contract memory_access Volatile + len not 4/8 -> InvalidSize.
- ifs forged-slot problem at boot scan.
