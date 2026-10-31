# proof design (PARKED 2026-10-31)

Parked by user 2026-10-31: build more of the os first (nvme parallelism, net, gpu, keyboard, mouse, disk, screen), then come back and see what the proof lib needs. Kernel may change before then.

Uncommitted proof work left in tree: kernel/pmm/buddy.odin (@(private) removed from buddy_init), kernel/kernel_model_test.odin (test_kernel_init).

- Snapshot plan (decided 2026-10-30): raw copy of kernelState bytes + test RAM buffer = snapshot/restore. Compare = walk real structs field by field (not memcmp: freed garbage + heap order differ). Test needs: context.allocator = kernel heap, pmm bitmap + cpus inside test RAM, testCpu set per step (not saved). Hardware state (CR3/TLB/LAPIC) not covered.

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

Done (committed b4419d7):
- `KernelState` + `kernelState` in kernel/kernel-state.odin (see Kernel facts). pmm pure, heap in state.
- Snapshot (user wrote, `when ODIN_TEST`): `KernelSnapshot{source, state, ram}`, `kernel_ram(k)` = phys 0 ..< totalPages*PAGE_SIZE via phys_to_ptr, `kernel_snapshot(k, allocator) -> (snap, err)`, `kernel_restore(k, snap)` (asserts k == snap.source, same RAM len), `kernel_snapshot_destroy`.
- Why raw works: kernelState bytes = roots only; everything else (heap objects, page tables, FreeBlocks, user memory) lives in test RAM. Restore to same addresses -> pointers valid. No replay needed.

User 2026-10-30: "leave the hardware alone as assumptions, same for adam". "take 1 bite at a time". OK to remove @(private) from buddy_init.
Claude's reading (not user words): callers = plain ProtectionDomains built directly in the start state, no adam_init imitation.

Uncommitted 2026-10-30 (not built / run yet):
- kernel/pmm/buddy.odin: @(private) removed from buddy_init.
- kernel/kernel_model_test.odin (user wrote): `test_kernel_init() -> backing`: page-aligned RAM (TEST_RAM_PAGES 128), pmm.directMapBase -> it, `kernelState = {}`, bitmap in RAM page 1, pages 1+bitmapPages.. free, buddy_init, heap.pmm = &pmm, pcidAllocator.next = 2.
- Watch: kernelState is a plain global, pmm.directMapBase is @(thread_local) in tests; tests touching kernelState (this + TestPcidRace) can race. Claude proposed `-define:ODIN_TEST_THREADS=1`; does not slow the proof (modelcheck.run single-threaded).

To do, in order:
1. Test setup, bite by bite:
   1a NEXT: smoke test `@(test)`: test_kernel_init, context.allocator = heap_allocator(&kernelState.heap), snapshot (temp_allocator, NOT kernel heap: it would live in the RAM it copies), alloc_pages one page, restore, expect RAM == snap.ram and freeLists == snap.state.freeLists. Run `odin test kernel -debug -define:KERNEL_BUILD=true`.
   1b cpus in RAM (heap): only non-hardware fields of cpu_init (kernel/cpu.odin:105): self, grants, sleepers, pcidSeenGen. Boot globals protdomain_new reads (kernelPML4, kernelImgGlobal, cpuHasPCID, cpuMeltdownVulnerable, CpuInfos/cpuInfosPhys) need test values.
   1c start state: N plain domains + testCpu.currentGrant.domain picks the caller per step (testCpu not in snapshot).
2. Hook snapshot/restore into modelcheck.run. OPEN: run needs a hashable value State; snapshot holds a slice. Decide state key (e.g. hash of snapshot bytes) with user. Same-meaning states with different heap layouts count as different = more states, still correct.
3. First proof bite: steps = prot_domain_create / prot_domain_destroy; rule S1.
4. `kernel_snapshot_compare(a, b)`: walk real structs field by field after restore, follow pointers, keep a->b pointer map (sharing must match), freeLists compared as page sequences. Also assert every lock in k is unlocked at snapshot time. NOT memcmp (freed garbage, heap/free-list order differ).
5. Later bites: resources+underlays (S2-S4), contracts (S5, S6, P1), pmm/page tables (S7), rings, grants + wait_on, race_check pass with poisoned frees.

Proposed rules (user has not approved each; first proof bite = S1):
- S1 protDomainPool: slot i in freeSlots <=> prots[i] == nil; freeSlots no dupes.
- S2 per domain resources: size > 0, phys+size no overflow, sorted by phys, no overlap.
- S3 every resource inside its underlay range.
- S4 underlay.refs == number of pointers to it (resources in all domains + ring.underlays + saveAreaUnderlay); no pointer to a freed underlay.
- S5 contract != nil => flags == {} (contracted never Present). One direction only: unmapped uncontracted resources exist (flags without .Present).
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
