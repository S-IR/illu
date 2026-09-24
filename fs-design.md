on disk we have [lenBytes, lastEdited][data] files right next to each other
folders are a special case of files recognized by them having last delimiter and maybe a magic value if they need
folders have the same header plus an array of [fileName, filePtr] which point to other files like mentioned above. they are 4096 bytes. stay in 1 place.
at the end they will have [MAGIC_NEXT_NODE, nextNodePtr] if they extend beyond that byte amount. linked list of parts. a folder can also be allocated with bigger size (or its nodes for that matter) but we extend through ptrs.

everyone has the lib to directly access the hard disk and write / read. we only do permission things.

perms is a runtime os concept. not a disk concept. init fs process has all perms and gives perms as it sees fit to anyone. perms have no special attributes.
obviously fs init or any other file can write their own files to cache perms for other programs

for small files we can put in the same 4k page more than 1 file. adjacent [lenBytes, lastEdited][data]'s. for perm we can use existing kernel primitive to only give specific length of perm on memory

After magic right now i lean towards reusing the same buddy allocator logic in kernel/pmm for the disk also. unless a better solution is found

at the beginning of partition we have [IFS_MAGIC, RootFolder] immediately
file path resolution is a map built in ram by each program. Init goes through and creates a map[hash]{hash, ptr}] (folders are just special files rememmber). he can give that map read only to anyone who wants it or seed other programs to create their own translation tables. it is meant to o(1) find files or folders. maybe stored on disk for fast retrieval.

security is somewhat murky now. perms on folders and files are handled through normal pml4 paging since they align.
we might want to build a way to "upload" security code in the kernel. exokernels proposed something like this, might be a useful abstraction.
or we can just create a trustworthy small adam daemon who handles any edge permission cases. that's also a direction.
in security i lean like this - decentralized trust model ensured by basic kernel primitives > daemon managing fine grained security >>> any special kernel logic for fs not-really-pritive primitives

issues now, resolved

- lastEdited trust: trust boundary is already "whoever has write perms" (they can already destroy/corrupt the data, a wrong timestamp is strictly smaller). so:
  - uncontended/solo-writer path (common case, no lease taken): self reported header field, no kernel involvement.
  - shared/locked path (rare): kernel stamps lastEdited itself at write_lease_release, since it's already in the loop right then. free and trustworthy exactly when it needs to be (shared = untrusted parties = needs trust; solo = only the writer ever reads it anyway).

- mutex: reuse the pml4 r/w bit itself as the lock, don't invent a separate lock object.
  - state per region (kernel side): holder domain id + expires_at. no queue, no wait list.
  - write_lease_acquire(region, duration_ms) -> granted | busy. can be triggered explicitly or implicitly via the write-fault itself (domain tries to write without the bit set -> faults -> kernel checks holder slot -> free: flip r/w on for caller, record holder+expiry, arm one-shot timer, resume).
  - write_lease_release(region) -> flip r/w off, stamp lastEdited.
  - timer fires if never released -> kernel force-flips r/w off, clears holder. this is the crash/hang recovery mechanism, no separate deadlock detection needed.
  - busy = no queueing, no blocking, no forced context switch between contending writers (only one can make progress anyway, alternating them is pure overhead). caller decides what to do on busy - retry, give up, whatever. parallelism already exists at the right granularity (other folders, other entries, other pages) without needing to fake it on the one contended region.
  - lease_acquire relies on the existing base perm check via the fault path - a domain can only fault into requesting a lease on memory it already has some mapping/perm for. lease governs *when* among legitimate holders, not *whether* you're one.

- wakeup: not implemented for now. no polling, no generation counter - that's throwaway work for a gap that's getting closed properly later anyway. deferred wholesale until real async event/upcall delivery into userland exists (currently doesn't - old prot-domain-listener-on-syscall idea was a dead branch, nothing there now). when it exists: register a handler on an addr, kernel redirects that domain's execution to the handler when the event fires (signal/upcall style, not futex-style sleep - we want "keep running, get interrupted", not "block until woken"). own domain's handler, own domain's risk, can't affect other prot domains. will be used by fs once built, not simulated in the meantime.

- stale data on reuse: zeroing the whole region on every free is too slow for the common case. default is no zeroing. keep an explicit zero-on-delete op available for when a domain actually needs that guarantee for what it's deleting, rather than paying the cost unconditionally.

- folder listing granularity: read perm on a folder means seeing every entry in it (filenames), no per-entry filtering, since it's just memory at page granularity. fine as default - the sub-page perm primitive (used for small-file packing above) already exists if finer-grained folder perms are ever needed.

- perm revocation: covered by the general prot domain revocation mechanism, not fs-specific.
