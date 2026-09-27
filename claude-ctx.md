# claude session context (2026-09-27)

## STOPPED HERE (end of 2026-09-27)
we were in the middle of writing kernel/mediated.odin (user typing it by hand from the chat print: syscall_mediated_create with single write-lock scope, syscall_mediated_access, helpers, resource_release freeing rules when underlay dies).
TOMORROW:
1. finish kernel/mediated.odin + remaining stage 1 bits (user_range_accessible mediated check, create/edit apply via domain_map_resource, dispatch cases, syscall.odin soa leftovers, adam test_mediated). then build.
2. underlay fixes: per-underlay lock / atomic refs instead of global memoryUnderlaysLock; memory_underlay_release returns freed bool; resource_release.
3. sweep whole codebase for 4KB-only assumptions (mem_region_valid, mmap syscall.odin:205, domain_map_resource, region_mappable steps by PAGE_SIZE, unmap loops, adam.odin, pmm) - 2MB/1GB pages must work.
resource_model_test.odin: user will delete it (api unstable, tests later).

SINGLE ADDRESS SPACE OPERATING SYSTEM. user applies code by hand; claude prints steps in chat, never edits project files unless literally told.

## done this session
- adam/fs (trusted nvme init): disk.odin (Disk + DiskDriver union), nvme-regs.odin, nvme-admin.odin, nvme.odin (nvme_init, nvme_queue_pair_create, dma_pages). boots in qemu: 64 io queue pairs, 131072 blocks.
- lib/nvme/nvme.odin public types (SQE/CQE/QueueInfo). lib/nvme/io.odin (Queue, prepare/push/poll/io_sync) was PRINTED, not written.
- lib/clock (tsc deadline helpers), kernel publishes tscTicksPerMs in CpuInfoPage, kensure invariant tsc. qemu needs `-cpu host,+invtsc`.
- qemu: nvme.img + `-device nvme` in .zed scripts.
- adam_start lost the old tests/spawn_printers (only cpu 0 prints) - user's choice so far.

## mediated memory stage 1 (in progress, user applying by hand)
applied by user: lib/syscalls enum (MediatedCreate=2, MediatedAccess=3, renumbered), MediatedRule/Op/Error types, wrappers; syscalls.asm renumbered (claude fixed dup line + edit=5, spawn=7); MemoryResourceFlag without Multiplexed.
kernel still references Multiplexed* in kernel/syscall.odin -> kernel does not build until that is deleted.

decisions:
- one syscall mediated_access(ops) with op.kind Read/Write (not separate read/write).
- rules live on the resource (overlay/permission), as `rules: []MediatedRule` shared immutable slice. grant = plain struct copy. slice freed when underlay freed (set only while underlay.refs == 1 so all holders share that underlay) -> MemoryUnderlay gets `rules` field purely as allocation owner, delete in memory_underlay_release.
- MEDIATED_MAX_RULES only bounds one mediated_create call.
- grants page granular. push right = W on ring slot resource, kernel rings doorbell, BAR stays with adam.
- one queue pair serves read/write/flush: opcode is value-set field whose values carry ptr perms (stage 2).
- processes can hold N queue pairs; spawner decides; delegable via prot_domain_edit. runtime "grant me more" mailbox: later.
- stage 2 field rules = templates at offsets inside a slot, repeated by stride (keeps rule count low).

## current step: SOA refactor of MemoryResource (before rest of stage 1)
- lmem.PageSize :: enum u8
- MemoryResource flat: phys, logical, size, flags(lmem.PageFlags), rules, pageSize, resourceFlags(bit_set u8), underlay. MemoryResources :: #soa[dynamic]MemoryResource.
- find/insert return indices (no element pointers in soa). resource_granted(owner, region) copies owner and overwrites region fields.
- applied: memory-resource.odin (flat struct, resource_granted, region_mappable, region_flags_grantable w/ cache bits), protdomain-resources.odin (soa helpers), protdomain.odin (two-pass create/edit: validate all, reserve_soa, apply w/ asserts; delete_soa).
- left: syscall.odin (delete Multiplexed*, mmap literal + reserve_soa, mfree removed.* fields, dispatch mediated cases), resource_model_test.odin, MemoryResourceFlags -> u8, lmem.PageSize -> enum u8, delete dead region_covers_kernel, unused core:mem import in memory-resource.odin.

## after SOA
stage 1 rest: kernel/mediated.odin (mediated_overlap, mediated_page_flags, domain_map_resource, syscall_mediated_create/access), user_range_accessible rejects mediated bytes, create/edit map through domain_map_resource, dispatch cases, adam test_mediated. adapt the stage 1 print to soa (indices instead of ^MemoryResource).
stage 2 field rules, stage 3 ring (TailDoorbell+Token), stage 4 loans + disk window. then lib/nvme io over mediated_access, disk counter test, then IFS lib.

## todo: per-underlay lock
memoryUnderlaysLock is one global spinlock for every underlay refcount (stop-the-world for all). move to a lock (or atomic refs) inside each MemoryUnderlay. note: refs only needs atomic add/sub + "was last" -> atomics may be enough, no lock. mediated_create's `refs != 1` check must stay atomic with setting rules (holder's domain write lock + atomic load of refs; a new grant needs that same domain lock, so refs can't rise concurrently from this domain, but check prot_domain_create/edit paths that increment without holding the owner's domain lock).

## mediated_create lock shape (decided)
one write-lock scope on the caller domain for: user_range_accessible(rulesPtr) -> copy -> validate copy -> find owner -> refs check -> set rules. check pointer BEFORE copy (else kernel reads arbitrary memory), validate only the kernel copy (TOCTOU).

## open / risks
- Volatile kernelPML4 4K mapping in mediated_create: ensure_table kasserts on large pages; check how pmm identity map is built before stage 3 (MMIO).
- large pages: mem_region_valid and mmap reject non-4KB; code should support all sizes. domain_map_resource must step by pageBytes.
- nvme admin/queue timeouts done; queue ids never reused; no flush yet.
- AMD tsc-deadline support unverified.
