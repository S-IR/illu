# claude session context

## STOPPED HERE (night of 2026-09-28)
goal now: working fs in adam, SECURITY IGNORED (no mediated memory, adam has full nvme access). user wants to see the fs working first, then decide security needs.
workflow: user hand-types code printed in chat, one small step per reply, review each paste. user sometimes says "you change it" -> then edit directly + `odin check adam -no-entry-point -target:freestanding_amd64_sysv -vet-shadowing`.
user is new to nvme: explain with diagrams when asked (controller/queues/doorbells/phase already explained).

done + booted in qemu (uncommitted):
- lib/nvme/nvme.odin: spec names replaced. Command {header: CommandHeader{opcode, commandId}, namespaceId, dataAddr, dataAddr2, args: CommandArgs #raw_union {io, identify, createCq, createSq, deleteQueue, setFeatures}}, Completion {result, sqHead, sqId, status: CompletionStatus{commandId, phase, code, codeType}}, completion_ok, QueueFlags {Contiguous, InterruptsEnable}. NVM_* consts deleted.
- lib/nvme/io.odin: Queue (using QueueInfo + sqTail/cqHead/inFlight/phase/nextCid), queue_init, queue_submit (release fence + doorbell), queue_poll (acquire fence, one completion), IoOpcode, IoError, queue_io_sync (1 block, polls with IO_TIMEOUT_MS, timeout leaves inFlight=1 => queue dead by assert).
- adam/fs: NvmeError enum per failure reason + `Error :: union #shared_nil {NvmeError, nvme.IoError}`. nvme_init/nvme_selftest -> Error, admin_run/dma_pages/nvme_disable/nvme_queue_pair_create -> NvmeError.
- nvme_selftest (ODIN_DEBUG only): new queue pair, write pattern to block 0, read back, compare. PASSES ("nvme: selftest ok").
- polling only. interrupts (MSI-X) later, after fs works.

NEXT:
1. IFS on-disk layout from fs-design.md: header block (MAGIC_IFS + root ptr), file header [len, fileType], dir entries [name, ptr] + MAGIC_FOR_FOLDER_LINKED_LIST chain. print step by step.
2. IFS format/mount/read/write over queue_io_sync, test from adam.
3. later: log sink (drivers.odin drops the Error to `.Failed, 0`), batching (queue_io_sync is 1 block sync), interrupts, then security design.

## BUGS (old; user said most are fixed since, ignore unless re-verified)
BUG A (introduced by us): kernel_pml4_map_mediated_mmio overwrites the kernel identity PTE (WB when the MMIO page sits in a hole below totalPages) with UC + local invlpg only. other cpus may keep a stale WB tlb entry -> mediated_access there does cached MMIO. no kernel-mapping shootdown exists.
  real fix: never touch identity entries. map MMIO rule pages at a kernel-only alias MMIO_ALIAS_BASE + phys in an otherwise unused PML4 slot of kernelPML4. alias entries are never present before map, and x86 never caches not-present translations (SDM vol3 4.10.2.3), so no flush needed on map. on unmap, stale alias entries still point to the same phys with UC; harmless (access validates live rules first; remap is identical). mediated_access uses alias addr for .DeviceMMIO, phys for RAM, under kernelPML4 cr3.
BUG B (pre-existing): paging_init identity-maps every page in [1, totalPages) WB RW, including holes/MMIO below top of RAM. relying on UEFI types is not safe (user rejected: ACPI tables can live in ReservedMemoryType on real firmware; BARs may sit in Reserved descriptors).
  real fix (no firmware trust): identity map only descriptors of real RAM types, AND make every non-RAM kernel access map its exact pages explicitly: acpi lib maps each table page read-only NX when it touches it (rsdp, xsdt/rsdt, each header then full length), ECAM already explicit (pci.odin:30), trampoline explicit, MMIO via BUG A alias. then nothing depends on the descriptor type of ACPI/MMIO memory. needs a check of every kernel phys deref before paging_init change: acpi, uefi params, framebuffer (unverified if used).
BUG C (question, unverified intent): PAGE_RW used for the kernel identity map includes .User. check whether pml4_deep_copy(..., true) strips it for domains and whether kernelPML4 should have it at all.
BUG D: kernel_pml4_unmap_mediated_mmio uses local invlpg only; fine only with BUG A alias design (stale alias = same phys, UC).

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
