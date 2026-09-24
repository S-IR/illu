# NEXT: drop Execution, kernel schedules VProcs only

No thread concept in kernel. A VProc = one domain's grant on one core. Kernel preempts/resumes VProcs. Threads are a userland thing on top.

## Plan

1. `Execution` -> `VProc` (kernel/execution.odin -> vproc.odin). Fields: `state`, `domain`, `schedulerState`, `core`, `vruntime`, `vdeadline`, `startTsc`, `tebBase`. Drop `next`. Keep `domain` at offset 704 (helpers.asm reads it).
2. `ProtectionDomain.executions` -> `vprocs: []^VProc` indexed by core (len(cpus)). Enforces one VProc per domain per core in O(1); occupied slot -> `AlreadyExists`. `executionCount` -> `vprocCount`.
3. `CpuState`: `rrHead/rrTail` -> `runq: [dynamic]^VProc` sorted by `vdeadline` + `minVruntime`. `rrCurrent` -> `current`, stays at offset 48. Reserve runq capacity at VProc create (each VProc occupies at most 1 slot on its core) so the IRQ path never allocates.
4. `runq_insert` (binary search + shift, same shape as `resource_upper_bound`/`resource_insert`), `runq_pop_min`, `runq_remove`.
5. Deadlines:
   - preempt: `vruntime += tsc - startTsc`, `vdeadline = vruntime + SLICE`
   - wake: `vruntime = max(vruntime, minVruntime - SLICE)` (interrupt waiters land near the front; replaces `enqueue_front`)
   - no weights for now.
6. Update: `timer_tick`, `interrupt_wake`, `syscall_interrupt_wait`, kill IPI path, `domain_destroy`, `cpu_prepare_sleep` (monitor runq len, not `rrHead`), `interruptExecutions` -> `interruptVprocs`.
7. Syscall `ExecutionStart` -> `VProcStart(handle, core, rip, rsp, arg0, teb)`. Explicit core, no round robin, `arg1` dropped. Update adam.odin, lib/syscalls, pe-load.odin.
8. Enable `CR4.FSGSBASE` (bit 16) in cpuid.odin next to PCID so userland can `wrgsbase` on thread switch.
9. Delete `execution_steal` (unused) and `rrCpuNext`.
10. Rewrite execution_model_test.odin for VProcs.

## How userland does threads (fibers / green threads)

```odin
UThread :: struct {
	rsp:   u64,
	teb:   u64,
	state: enum { Ready, Blocked },
}
```

Plus a ready queue in the domain's own memory.

```
uthread_switch(from, to):
    push rbx, rbp, r12-r15
    from.rsp = rsp
    rsp = to.rsp
    wrgsbase to.teb
    pop r15-r12, rbp, rbx
    ret
```

- Only callee-saved regs, ~20 instructions, no kernel entry.
- Block/yield (lock, pipe, file io) -> `uthread_switch` to next ready thread.
- Parallelism: domain with N VProcs on N cores runs N threads at once, all pulling from the domain's shared ready queue (userland spinlock).
- Win32 `CreateThread`: ntdll_immitator allocs stack + TEB, pushes a `UThread`. No syscall.

## Known gaps until upcalls exist

- No preemption between a domain's own threads. A thread spinning in `while(1){}` starves its siblings on that core. Fix later with a timer upcall: kernel dumps regs into domain memory and jumps to the domain's handler, which saves them into the current `UThread` and picks another.
- `InterruptWait` blocks the whole VProc, so the domain loses that core while waiting. Dedicate a VProc to waiting, or poll.

## Pending fs-design.md edit (approved direction, not applied)

- Header `[lenBytes, lastEdited]` -> `[lenBytes, type:u64]`. `type` is opaque to the os; apps put their own headers (mtime etc.) in data.
- Remove the `lastEdited trust` bullet and the lastEdited stamp in `write_lease_release`. Keep lease `expires_at`.
- Open: reserved `type` value for folders? Reword mtime line in fs-reqs.md?
