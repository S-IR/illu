Fixed and booted:

1. GS base (TEB) was lost in the sched refactor. Fixed with gsBase in UserSaveArea plus the wrmsr in run_resume.
2. protdomain_destroy never released its memory, so destroyed domains leaked. Fixed.
3. mmap with several regions corrupted the page allocator: each region freed its own piece of one buddy block with the wrong size. Fixed with one shared underlay per mmap, plus asserts in buddy_free.
4. The lld-link /machine warning. Fixed.

Fixed and built, not booted yet: 5. NX hole: a parent could hand an NX page to a child as executable. Fixed with region_flags_grantable. 6. run_resume loaded CR3 without the domain's PCID, so user code ran on PCID 0. Fixed. 7. The scheduler locked the target domain on every resume and preempt, so another domain could stall a whole CPU. Fixed: the save area is now read and written directly, and a fault inside that code kills that grant instead of panicking. 8. Preempt wrote the save area through the kernel identity map, which is wrong whenever logical ≠ phys. Fixed: it now goes through the domain's CR3. 9. TLB shootdown:

- it did nothing without INVPCID, and callers skipped it when pcid == 0;
- it could deadlock (waiting for an acknowledgement from a CPU in a syscall with interrupts off, while holding the domain lock);
- its acknowledgement count was wrong.

  Replaced with tlb_wait_domain_flushed and a per-CPU tlbEpoch counter. No IPIs, and it waits only after all locks are released.

10. prot_domain_destroy race: it could destroy the wrong domain, or let userland hit a kernel assert. Fixed: the lookup and the unlink now happen under one lock.
11. prot_domain_create checked permissions, dropped the lock, then used the owner without re-checking. Fixed: it's now one pass under both locks.
12. prot_domain_edit .Add could apply only half the regions if it failed partway. Fixed: it reserves space first, so it can no longer fail partway.
13. No validation of MemRegion:
    - a bad page size caused a divide by zero;
    - misaligned addresses hit kernel asserts;
    - worst: a domain could map pages into the kernel half of its own page tables.

Fixed with `mem_region_valid`. 14. mfree didn't check its removed allocation. Fixed.

Not done: 15. pe_run leaks its stack, TEB, save area and import mmaps, both on failure and on success. You asked for the defers; not written yet. 16. Every interrupt vector uses IST 1, whose top is the same as the kernel stack top. Any interrupt or exception taken in kernel mode resets RSP and overwrites the kernel stack that was running. 17. Suspected, not verified: on Meltdown-vulnerable CPUs, the domain page tables map only the kernel image. interrupt_dispatch does fxsave %gs:CPU_USERFX (heap memory) under the domain's CR3, which would fault. 18. pe_run returns handle 0 instead of -1 when domain creation fails.

Design problems (not bugs):

- CpuState has too many fields.
- The sched code uses a lot of locks.
- RWLock is unfair, so a stream of writers can starve readers.
- The kernel tests are commented out of the build.
- The firstpe: debug prints are still in adam.
