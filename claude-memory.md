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

- Mutable kernel state = `kernelState: KernelState` (kernel/kernel-state.odin): pmm, heap, protDomainPool, pcidAllocator, tlbGenCounter, ringPool, cpus. Boot-only globals (cpuid flags, idt, gdts, kernelPML4, directMapBase, entryRegionNext) stay loose.
- pmm is pure: every proc takes `p: ^PMM` (freeLists + earlyAllocNextPage inside PMM). lib/alloc holds no globals: `Heap{freeList, lock, pmm}` passed via `heap_allocator(&heap)` -> Allocator.data. Owners: kernelState.heap, adam `adamHeap`, ntdll_immitator `processHeap`.
- Snapshot plan (decided 2026-10-30): raw copy of kernelState bytes + test RAM buffer = snapshot/restore. Compare = walk real structs field by field (not memcmp: freed garbage + heap order differ). Test needs: context.allocator = kernel heap, pmm bitmap + cpus inside test RAM, testCpu set per step (not saved). Hardware state (CR3/TLB/LAPIC) not covered.

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

1. PROVING the kernel (lib/modelcheck). Full plan in section "Proof plan" below. Next concrete step = bite 1.

## Proof plan (decided with user 2026-10-30)

Decisions:
- ONE proof for the WHOLE kernel, ONE test file, grown bite by bite. Not per-syscall proofs (bugs live across call sequences).
- Run the REAL Odin code. No abstract models, no symbolic execution, no Odin parser, no binary analysis. Rules describe what must / cannot happen on the real state; the checker runs real syscalls in every order and checks every rule after every step. Bounded (few domains, small args), not "all sizes".
- Rules talk about STATE (who can touch what memory, refcounts, ownership), never about how a syscall works -> a redesign only kills that part's rules.
- Order: stable core first (domains, resources, underlays, pmm, grants), ring + contracts after pins / Copy/List land. Write ring/contract rules ready for those refactors.
- Errors: error = return values garbage, kernel state must still be OK (rules checked after error steps too). Stronger "error changes nothing" = possible, user undecided.
- Extra wanted later: contract VM step check (P1: validate-passing rules never trap, always halt; only for the contract VM, NOT a general modelcheck feature); poison freed blocks so race_check catches use-after-free (P4: Delete vs memory_access).
- Dropped: symbolic path enumeration (B), refinement vs abstract spec (C).

Bounds (user 2026-10-30: MUST make sure the bound is not a problem; worry about size as little as possible). Plan, all three:
- B1 inductive step check: build kernel states directly where all rules hold (not only reachable from boot), run ONE syscall, check all rules still hold. Pass = no sequence of any length breaks the rules. Valid built state that breaks = bug or missing rule. OPEN: whole kernel or contract-only (user said contract-only earlier; Claude recommends whole kernel).
- B2 shrink limits under `when ODIN_TEST` so full / grow / wrap / max all hit in small runs: PCID_MAX ~4, MEMORY_RESOURCES_STARTING_CAP 1, ring depth 2 and 3, pool slots 2-3, etc.
- B3 boundary args for every number: 0, 1, limit, limit+1, max, phys+size overflow.
- Left: object count stays small; argument = code treats element N like element 2 (no per-index special case). Argument, not machine-checked.
- Full all-sizes proof = theorem prover = dropped.

Done (uncommitted, builds, pmm + kernel tests pass):
- `KernelState` + `kernelState` in kernel/kernel-state.odin (see Kernel facts). pmm pure, heap in state.
- Snapshot (user wrote, `when ODIN_TEST`): `KernelSnapshot{source, state, ram}`, `kernel_ram(k)` = phys 0 ..< totalPages*PAGE_SIZE via phys_to_ptr, `kernel_snapshot(k, allocator) -> (snap, err)`, `kernel_restore(k, snap)` (asserts k == snap.source, same RAM len), `kernel_snapshot_destroy`.
- Why raw works: kernelState bytes = roots only; everything else (heap objects, page tables, FreeBlocks, user memory) lives in test RAM. Restore to same addresses -> pointers valid. No replay needed.

To do, in order:
1. Test setup (one test file in kernel/): test RAM buffer, directMapBase -> it, PMM over it with bitmap INSIDE RAM, kernelState.heap.pmm = &kernelState.pmm, context.allocator = alloc.heap_allocator(&kernelState.heap), cpus allocated in RAM, boot domain (adam). testCpu set before each syscall to pick the caller (not part of the snapshot).
2. Hook snapshot/restore into modelcheck.run. OPEN: run needs a hashable value State; snapshot holds a slice. Decide state key (e.g. hash of snapshot bytes) with user. Same-meaning states with different heap layouts count as different = more states, still correct.
3. Bite 1: steps = prot_domain_create / prot_domain_destroy; rule S1.
4. `kernel_snapshot_compare(a, b)`: walk real structs field by field after restore, follow pointers, keep a->b pointer map (sharing must match), freeLists compared as page sequences. Also assert every lock in k is unlocked at snapshot time. NOT memcmp (freed garbage, heap/free-list order differ).
5. Later bites: resources+underlays (S2-S4), contracts (S5, S6, P1), pmm/page tables (S7), rings, grants + wait_on, race_check pass with poisoned frees.

Proposed rules (user has not approved each; bite 1 = S1):
- S1 protDomainPool: slot i in freeSlots <=> prots[i] == nil; freeSlots no dupes.
- S2 per domain resources: size > 0, phys+size no overflow, sorted by phys, no overlap.
- S3 every resource inside its underlay range.
- S4 underlay.refs == number of pointers to it (resources in all domains + ring.underlays + saveAreaUnderlay); no pointer to a freed underlay.
- S5 contract != nil <=> flags == {} (contracted never Present).
- S6 each ContractRules owned by exactly one resource; r/w pass contract_validate; not both empty.
- S7 pml4 maps exactly the domain's Present resources (logical->phys, flags), nothing else in user half.
- Step rules (need before+after state; OPEN how run passes both): T1 only caller + domains caller has W on (authorityPtr) change. T2 no new access unless caller held it (authority never grows). T3 (optional) error changes nothing.

Open decisions for the user:
- serialPrintLock (kernel/syscall.odin:20, debug-print lock): into KernelState or not.
- State key for run (step 2) and before+after for step rules.
- "error changes nothing" yes/no.
- P5 (adam's contract programs, e.g. nvme): how, given no symbolic execution. Concrete boundary values = strong but not full proof.

Notes:
- lib/modelcheck tests: run killed at 300s by me, result unknown (package untouched).
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
