# claude memory (terse)

## Work rules (user)

- Never invent limits or design and present them as fact. Facts: cite file:line or spec. Proposals: label them, the user decides.
- Context = files in the working tree only. Read git history only when the user asks.
- Don't flip-flop. Pick one recommendation and keep it unless the user changes it.
- Default: step-by-step pseudocode, user writes code. Write files only when explicitly asked. No comments in code.
- Keep answers SHORT (user begs). Explain with concrete trace tables.
- Check plan lines against the design's purpose before building on them.
- APIs are batched + async by default, never block. Sync helpers only as wrappers over the async API.
- err is always the LAST return value. Exception: syscall_dispatch / raw foreign decls keep err first (rax). Old violators: syscall_mmap, syscall_prot_domain_create.
- Error returned = other outputs garbage. Exceptions allowed when they make sense.
- Never boot qemu. The user runs `.zed/debug.sh` / `.zed/prod.sh`. Build with `odin run . -debug` at most.
- _NO_LOCK fns take no locks at all; the syscall takes every lock up front. Never nest domain read locks (writer bit between = deadlock).
- To debug: get data first (prints), then hunt the bug.

## Kernel facts

- All syscall errors = shared.Error (SYSCALL range 0x400). DebugPrint prints label + value.
- Locks take `guards: [][]u8`, same g for lock and unlock. Helpers with @(deferred_out): domain_read/write_lock, domain_guards (kernel/protdomain.odin), ring_pool_read/write_lock, ring_lock (kernel/ring.odin). protDomainPool and cpu guards are still inline.
- MemoryResource: #soa kept (bench lib/soabench). Rules in `contract: ^ContractRules{r, w}`.
- user_copy_in/out(_NO_LOCK), user_range_accessible_NO_LOCK in kernel/protdomain-resources.odin.
- wait_on(addr, old, deadline) kernel/grant.odin: futex-like, needs R on 8-aligned u64. If the cpu can't mwait (idleCount == 0, e.g. KVM), sleep_target polls sleepers every tscTicksPerMs / SLEEPER_POLLS_PER_MS.
- Contracts: kernel/contracts.odin (create, memory_access, validate, contract_run_NO_LOCK). Design in contracts.md.

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

## Next (user's order)

1. Talk about proving what we wrote: ring, contracts, nvme, ifs. Tool: lib/modelcheck. The user decides the plan.
   - Claude's idea: besides the contract interpreter, prove each contract program adam installs (e.g. Accept => LBA in window && PRP1 page aligned && HasPerm). The VM only jumps forward and the slot is <= 64 bytes, so checking every path is cheap.

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
