# claude memory (terse)

## Work rules (user, 2026-10-26)
- Never invent limits or design and present them as fact. Facts: cite file:line or spec. Proposals: label them, the user decides.
- Context = files in the working tree only. Never read git history (deleted files) as context.
- Don't flip-flop. Pick one recommendation and keep it unless the user changes it.
- Print code only when asked. Write files only when explicitly asked.
- Hard rule (2026-10-27): model checks run the ACTUAL code, never a hand-written model of it. Proving is the end goal; design code so it can be proven.

## Errors (2026-10-27)
All syscall errors = shared.Error (SYSCALL range 0x400). Per-syscall enums + ProtDomainTargetError deleted. Kernel and userland return shared.Error, use or_return.

## Contracts work (2026-10-26, in progress)
Design: contracts.md "CONTRACT" section. Work order: updates.md section 1.

Done (odin check passes on kernel with KERNEL_BUILD=true and on adam):
- lib/syscalls/contracts.odin: ContractOp, ContractRule (16B #assert), ContractDesc, ContractAccessDir,
  CONTRACT_ACCESS_MAX, userspace wrappers syscall_contract_create_userspace / syscall_contract_memory_access_userspace (inside when !ODIN_TEST && !KERNEL_BUILD).
- lib/syscalls/syscalls.asm: stubs nr 7 (create) and nr 8 (access), both 4 args (rcx -> r10).
- lib/syscalls/syscalls.odin: Syscall enum ContractCreate, ContractMemoryAccess + foreign decls.
- kernel/syscall.odin: dispatch cases.
- kernel/memory-resource.odin: MemoryResource.rContractRules, wContractRules: []syscalls.ContractRule.
- kernel/contracts.odin: contract_validate, contract_rules_copy_in (user_copy_in, validate the kernel copy), syscall_contract_create
  (both rule sets empty -> InvalidRules, owner not contracted, W needed only if wRules, target overlap, insert flags {} resource, underlay increment).
- resource_contracted helper; grant refusal in prot_domain_create + edit Add; assert in resource_granted (regrant = refused).
- Edit Delete: frees rules, always releases underlay, skips unmap/tlb for flags {}; defer always runs, only shootdown conditional. protdomain_free frees rules.
- pmm.map_kernel_mmio: BARs + pcie config pages mapped UC into kernel direct map in adam_init (direct map was RAM only). Boot-tested (nvme CAP read).
- Decision: replacing rules = Delete + Create, no in-place replace.

Open / next:
- NOW: proof tooling, updates.md 1a (cpuid stub done -> spinlock race checker -> engine model check -> contract race check), then ring.
- contract_run (pseudocode in chat 2026-10-27: 8 regs, r0 = dst offset, r1 = len, core:encoding/endian for LE loads/stores, assert next > pc).
- user_copy_out helper (mirror of user_copy_in, write = true).
- syscall_contract_memory_access: copy in before lock, caller read lock over find + run + device access, copy out after lock. len 4/8 = one volatile op.
  Proposal (undecided): Volatile resource + len not 4/8 -> InvalidSize.
- contracts.md still says "caller owns with W"; now W only needed for wRules.
- contract_validate odin test. odin test kernel already broken: cpuid.odin:158/161 'context' not defined.
- Copy buffers design, pins, ring (tail replay / in-flight overwrite / unpin-during-DMA holes stay until then).
- ifs forged-slot problem at boot scan: undecided (option c = per-subtree ranges in adam config, a = reject overlaps).

## Race checker design (2026-10-27, agreed in chat, not written yet; updates.md 1a.2)
- Harness = new lib/modelcheck/race.odin (imports core:thread/sync). run() itself unchanged.
- Seam: lib/spinlock gets `when ODIN_TEST { schedHook: proc "contextless" (kind: PointKind, addr: ^u32) }` + point() before every atomic,
  point(.Relax, addr) before cpu_relax. Spinlock must NOT import the harness (core:thread breaks freestanding, like core:flags did); harness sets spinlock.schedHook.
- Baton scheduler: real threads, each parked on own sema; controller picks one thread to run until its next hook point. Deterministic, replayable.
- Relax = thread blocked until addr^ != value saved at relax (kills infinite spin schedules).
- execute(prefix): fresh threads, follow prefix, past frontier pick first runnable, always run to end (threads can't be aborted). Returns runnable set at frontier + err (Deadlock / StepBound / Invariant).
- RaceState {choices, len, preemptions, err} is the modelcheck State; next = one transition per runnable thread, label "T<n>"; inv = err == .None.
- Preemption bound REMOVED 2026-10-28 (user: limits that break provability are banned). Full exploration.
- Test bodies put a ghost yield point inside the critical section, else mutual exclusion breaks are unobservable. Invariant: writers == 0 || (writers == 1 && readers == 0).
- Cases: W+W, W+R, R+R, W+R+R, nested reader vs writer (expected deadlock).
- assert_contextless in real code kills the process: MODELCHECK_TRACE=1 env prints each prefix before running it.
- SC memory model: UNVERIFIED assumption (unlock is a plain store). User accepts it for now.

Progress (2026-10-27):
- Step 1 DONE: lib/spinlock/spinlock.odin has PointKind {Atomic, Relax}, `when ODIN_TEST` schedHook, point(); point(.Atomic) before every atomic, point(.Relax) before every cpu_relax. odin check kernel/adam pass.
- Steps 2-4 DONE (2026-10-28): race.odin has controller_step/start/finish, Test {bodies, data, reset, inv}, RaceError, Schedule,
  execute(prefix) -> (frontier, taken, err), RaceState {test: ^Test, prefix, preemptions, err}, race_next, race_inv, race_check(^Test).
  Errors past the frontier are reported at once with the full taken schedule. odin check lib/modelcheck passes. Untested (no bodies yet).
  Claude wrote race_next/race_inv/race_check on user request.
- Step 5 DONE (2026-10-28, Claude wrote on request): lib/modelcheck/race_test.odin, RWState + rw_writer/rw_reader/rw_nested_reader, 5 tests.
  odin test lib/modelcheck: all pass, ~6s. Deadlock test leaks parked threads (expected, runner warns).
- Mutation check (scratch copy, writer skips reader drain): real assert spinlock.odin:91 fires in a worker -> controller waits forever -> HANGS.
  assert_contextless hardcoded (base/runtime/core_builtin.odin:1745). Test runner signal handler ignores sub-threads (core/testing/signal_handler_libc.odin).
  Timeout REJECTED by user (heuristic). Planned B, not approved/written yet: lib/shared check + failHook (when ODIN_TEST), spinlock uses shared.check,
  harness fail -> .Failed + park forever, worker_entry sets context.assertion_failure_proc, RaceError .Assert. Other crashes (segv/bounds) still hang = never a false pass.
- 2026-10-28 no bound: W+W, W+R, R+R, nested deadlock pass. W+R+R exceeds run() max_states 200000 = fail, not proven.
- 2026-10-28 crash policy (user): no signal handler, no plan B. Worker crash = runtime prints message, test hangs = not proven.
- 2026-10-28 reduction (footprints/canonical/Load-Write split) REVERTED: only 25-40% cut. Kept: execute returns at once on Invariant.
- 2026-10-28 DECISION (user): plain data races must be proven, no gaps. Source-level wrappers/lint have gaps (raw ptr writes, mem.copy).
  Chosen: compiler instrumentation from -sanitize:thread as the seam, OUR handlers, NO TSan runtime/detection.
  Feasibility PROVEN (scratchpad/tsan/t.odin): odin build -sanitize:thread -build-mode:obj, then link
  `clang t-*.o -o t.bin -Wl,-z,now -Wl,-z,relro -lm -lc -pie` (no -fsanitize=thread). Own @(export, link_name="__tsan_write8", no_sanitize_thread)
  handler gets called on every plain write. Linking with odin's normal -sanitize:thread fails: multiple definition vs libclang_rt.tsan.a.
  Seen symbols: __tsan_func_entry/exit, __tsan_read8/write8. TSan pass drops a read when a write to the same addr follows in the same block.
  Not covered: hand-written .asm (asm_helpers, syscalls.asm), list by hand.
  Next (not started): list every __tsan_* symbol the pass can emit (read/write 1-16, unaligned, atomics = handler must DO the op, memcpy/memset, init);
  handler = scheduler point; harness + core:sync/thread accesses must pass through (thread-local in-hook flag); stack accesses are thread-local.
  Open risk: a point on every access = far more steps = worse explosion.
- Teaching note: user got it only after a concrete line-by-line trace table (controller | A | B). Explain with traces, not jargon.

## Proof tooling expansion (2026-10-27, PROPOSALS, user has not decided)
Modelcheck:
1. Asserts as findings: under ODIN_TEST route assert failures (now default_assertion_contextless_failure_proc kills process) to the harness: record assert + prefix, park thread. Every existing assert = free invariant.
2. DPOR-lite: points carry addr; steps on different addrs commute, interleave only conflicting ones. Allows K > 2 / more threads.
3. Parent indices instead of copied path slices in run() (already planned).
4. Generator helpers for pure fns (all values of small enum/range, all op sequences <= N). Needed by engine check 1a.3 (all bounded programs into real contract_validate).
Codebase:
5. One atomics wrapper package (e.g. lib/atomic) calling point() inside load/store/cas/xchg, so every lib (spinlock, ring log, nvme ring, kernel pools) gets the seam.
6. Hardware behind proc params/structs (page tables, TLB shootdown, MMIO, doorbells) so real kernel logic runs in userland tests with fake devices. Needed for 1a.4.
7. Keep pushing pure fns: explicit inputs = enumerable.
8. TSO store-buffer mode later, before proving lock-free rings (SC misses x86 store->load reordering).
Suggested order: 1, 5, 6 (unblock contract race check).
