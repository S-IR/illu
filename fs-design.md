IFS:
at the start we have MAGIC_IFS to distinguish.
we have files represented as [len:u64, fileType:u64, data] stored next to each other on disk. user switches on that type and interprets the rest as he sees fit.
dirs are just a normal type of file but inside they include an array of [fileName, ptrToFile]. remember single address space os. they will have stable ptrs, meaning they will either be allocated with the exact amount of size at the start or at the end their last bytes will be [MAGIC_FOR_FOLDER_LINKED_LIST, linkedListNextPtr] to go to the next memory ptr
at the start of the disk we have [MAGIC_IFS] then immediately afterwards root ptr. thats why we need stability
path resolution is a process built (or cached) at init. it remains in disk. it will be a map[hash]ptrToFile (remmeber folders are just files) map. when some dude will search for a file it will use his own map. hash can be whatever 128 is fine by me
maps can be shared to other spawned processes or seed material can be given for fast calc.
any other file type headers are to be written with logic user side lib side switch on fileType

hardware facts:
nvme is not memory mapped. bar0 is only registers. data moves by commands "read lba X count N into ram addr Y" via dma.
paging only checks cpu loads/stores. iommu only checks ram addr Y, not lba X, and is per pci function not per process (no sr-iov). device commands carry addresses nobody checks.
=> no fs daemon. kernel never parses nvme or knows fs. everything boils down to memory perms + mediated memory.

disk perms = memory perms:
- disk window: fake phys range above ram, DISK_BASE + lba*blockSize. disk extents are no-map MemoryResources (tracked, never mapped), granted/split via prot_domain_edit, checked by resource_find_containing.
- you got write perm on a folder range, you can write to the folder or extend it.
- fs init holds the whole disk window, creates the nvme queues as mediated memory, hands each process its own queue pair + its disk ranges.
- every process uses the userland fs lib directly on its own queue. no raw nvme access for anyone.

mediated memory (kernel primitive, replaces MultiplexedMemory*):
only kernel touches mediated bytes. everyone else via mediated_read/mediated_write.
kernel knows no device types, only generic mechanisms. owner lib (adam) fills offsets/values per device.
core: a device dmas to any address it finds. kernel is the only one that says "go" and the one that hears "done".

rules (mediated_create, set by owner once, immutable):
- rule: phys, len, flags {MediateRead, MediateWrite, PtrNeedsRead, PtrNeedsWrite}.
- caller holds R+W on every rule range and is sole holder of touched pages. rules never overlap. kernel keeps them in one global sorted array by phys.
- ptr field: 8 byte field. value v means range [ptrBase + v<<ptrShift, +ptrSize). writer must hold the needed perm on that range inside one resource (no-map disk window counts). ptrSize pow2, target aligned to ptrSize. target must not contain mediated bytes.
- value field: field & mask must be one of a set. (xhci trb type, idt=0, ioc=1).
- bytes nobody is granted write on are constants set by the owner.
- ring: {slots, stride, depth, token, arm, doorbell, witness, witnessStride, witnessToken, witnessDoorbell}.
  arm kinds: TailDoorbell (kernel writes tail) | CycleBit (kernel writes each slot's cycle bit last, constant doorbell, rearms owner's link slot on wrap).
  witness kinds: Token (out of order, token in witness entry) | InOrder (witness gives a position, every slot up to it is done).
  witness doorbell value: index or address.
  2 <= depth <= 65536. stride*depth fits the slots resource. token fits stride, witnessToken fits witnessStride.
  kernel state: tail, inFlight, 2 bits per slot {Free, Written, InFlight}, witness head + phase.
  nvme = TailDoorbell+Token. e1000 = TailDoorbell+InOrder. xhci = CycleBit+InOrder. gpu = TailDoorbell+InOrder(fence). ahci: not covered.

grants (prot_domain_edit):
- byte granular on mediated memory. copies overlayFlags.
- page bits derived: domain gets page mapped R/W only if it holds that perm on the whole page and no byte in it is mediated for that direction.
- push right on a ring = W grant on its slot fields + its doorbell.

access (mediated_read / mediated_write):
- op: phys, buf, len. batch validated all or nothing (failedIndex), then executed in order.
- op range inside one caller resource with the right perm.
- mmio: len in {1,2,4,8}, aligned, one instruction. userland lib picks sizes. ram: any len, memcpy.
- ptr/value fields must be fully covered by the op, else reject.
- kernel copies user buffers in before validating.
- ring batch order:
  1. retire: kernel reads new witness entries, ends their loans, frees their slots, writes witness doorbell.
  2. slot writes: only on Free slots. ptr check, loan starts, slot -> Written.
  3. doorbell write n: slots [tail, tail+n) all Written, inFlight + n <= depth-1. kernel stamps tokens, slots -> InFlight, arms, rings.
- client never supplies a doorbell value.

loans (time multiplexing of memory):
problem: kernel checks a ptr at write time, device uses it later. if the target changes owner in between, device hits the new owner.
- loan starts at slot write, ends at retire (witness shows the slot done).
- ring guarantees a checked slot runs at most once, so the witness is trusted.
- target perm change with a live loan:
  ram + iommu: iommu unmap + iotlb flush, page quarantined from devices until the loan ends. change goes through.
  ram without iommu, disk: .Busy until the loan ends. kernel never blocks on a loan.
- hung device: loans stuck until adam resets the controller (failure path only).
- tokens: never reissue a token whose loan ended without a witness. poison value never issued, witness prefilled with poison, kernel poisons entries it read.

nvme with it:
- per process: one read queue pair + one write queue pair (direction flips needed perms).
- sq slot: client granted write on prp1 + slba only. prp1 PtrNeedsWrite (read q) / PtrNeedsRead (write q), ptrSize block. slba ptrBase DISK_BASE, ptrShift log2(block), ptrSize block, need R (read q) / W (write q).
- constants: opcode, nsid, nlb, psdt=0, fuse=0, prp2=0. token = cid. witness = cq (stride 16, cid at 12). cq mapped RO to client.
- loop: 1 syscall per batch = retire + fill slots + push n.

prior art: xok XN (uploaded untrusted deterministic functions for disk), zircon PMT quarantine, linux dma_fence finite time rule, gray-cheriton leases.

existing bug: prot_domain_edit Add doesnt copy overlayFlags + maps every page => granting a Multiplexed region maps it raw into target.

OPEN:
- 4KB page perm granularity vs packed small files (~50% < 2KB): pad to 4KB or accept neighbor exposure. block sized disk ranges make this block granular.
- delete + stable ptrs: reuse of freed space makes old ptrs hit other files.
- free space allocation without daemon/shared corruptible map.
- concurrent folder extend: lock word or append-only atomics.
- crash consistency: journal, cow, or ordered writes with ptr last.
- growing file with neighbor right after: move (breaks ptrs) or chain like folders.
- windows metadata (mtime, attrs): fixed header on every file vs per fileType.
- per-process path map staleness on rename/delete by others.
- nlb fixed to 0 => 1 block per command. batch hides it, revisit if slow.
  candidate: nlb = 4096/lbaSize - 1, ptrSize 4096 for prp1 and slba (slba aligned to 8 on 512B lba).

OPEN (security):
- revoke dos: client keeps rearming loans on a shared target. userland fix: revoker first pulls the clients slot + doorbell grants.
- prp page crossing: target aligned to ptrSize, ptrSize <= 4096 and divides 4096.
- flush: opcode is constant per queue, needs a flush slot or queue.
- msi-x vector per cq grantable to client: unverified.
- cqe posted only after data dma done (pcie ordering): believed, unverified.
- xhci: interrupter count on consumer controllers, setup trb cross device harm: unverified.
- pathmap_scan_dir: one corrupt dir or name file aborts the whole scan (.Corrupt returns). known, deal with it when fs security starts.

porting state: lib/nvme (queue.odin: SQE/CQE/Ring/doorbell_offset, info.odin: QueueInfo) printed in chat, not written.
controller regs + commands + admin ring move to lib/fs_init (adam only).

DECIDED 2026-10-01 (security still ignored at implementation time, design is for when it returns):

grow / move a file or dir:
1. alloc new range. 2. copy data. 3. transfer_perm(oldPtr, oldSize, newPtr, newSize). 4. rewrite parent entry {ptr, len} (ptr last). 5. Notify(parent dir range).
- old range is reclaimed by its space owner (or by the boot scan).
- Superblock needs rootPtr (ROOT_PTR const can't move). growing root = rewrite superblock.
- huge files may still use chunks instead of moving.

entries + len (DECIDED 2026-10-01):
- every file (dirs too) is described by a header {ptr, len, nameLen} + name stored in its PARENT dir's data. root's header = superblock.
- len = exact bytes the file owns on disk. no block rounding. boot scan marks [ptr, ptr+len) used.
- ifs knows nothing else. any type specific metadata is the first part of the file's data, written by that type's user lib:
  dir: [count u64][header0][header1]... count marks the live entries, bytes after them up to len are room for appends.
  windows file: [userSize, attributes, times, ...][content]. userSize <= len, rest is room to grow.
  plain file: no header, len = size.
- grow: extend in place if the bytes after the file are free, else alloc + copy + move. extra room held back by the running allocator is RAM only and free again after a reboot.

names + chunks (ifs only knows ptr + len + trailing '/'):
- dir = name ends with '/'. file types by suffix, user lib side.
- names UTF-8 (WTF-8 in win layer), case sensitive. '\' escapes the next byte.
- file chunks: "foo.txt|0" then entries named just "|1", "|2" ... right after it (name stored once, adjacency = same file). glued by the user lib. "\|" = literal pipe.
- dir continuation: an entry named "|/" anywhere in the dir = this dir continues at its {ptr, len}. ifs sees a dir, boot scan follows it. real dir named "|" = "\|/".
- dir api is dumb: whole dir in caller RAM, dir_append edits it and returns the changed byte range or DirFull. caller decides what to write and what to do when full (realloc, chunk, ...).

DECIDED 2026-10-02: dir layout = no names in ifs.
- ifs dir = [16B slots {offset u64, len u64}]. no flags, no types in slots.
- FILE NAMES DETERMINE FILE TYPES (dirs included: dir = name ends with '/'). the scan reads name files to find dirs.
- name file = [HeaderOfNameEntry{slotIdx, nameLen u64}][name bytes][pad to 8] ... slotIdx 0 = end. rename rewrites the name file.
- slot never moves -> per file perm = that slot's 16 bytes, stable. only a whole dir grow moves it (transfer_perm).
- names live in a user lib: each dir's slot 0 points to that dir's name file (bytes the name lib interprets: name -> slot index). case rules, escapes, chunks, windows quirks all live there.
- slots and names are two places that must agree. write order makes crashes leak, never corrupt:
  create: slot first, then name (crash = nameless slot, scan can see it and reclaim).
  delete: name first, then slot.
- removes from ifs: escape rules, "|/", variable length entry parsing (dir_entry, padding).
- cost: create/delete touch two places; name parsing still exists, just moved to the lib.

transfer_perm(oldPtr, oldSize, newPtr, newSize) syscall (kernel, generic, knows no fs):
- caller needs W on all of both ranges. ranges must not overlap.
- kernel scans every domain (protDomainPool write lock, then each domain):
  resource == whole old range -> whole new range.
  resource inside old range -> shifted by offset, clipped to [new, new+newSize), removed if empty (underlay release).
  resource containing old range (space owner / arena) -> untouched.
  resource straddling old range edge -> reject.
- mapped resources: unmap old, map new, tlb shootdown. disk window resources: list rewrite only.
- no allocation (count same per domain except removals), re-sort soa by phys.
- TransferPermError :: enum u64 {None, InvalidRange, NoPermission, Straddles}
- with loans: live loan on old range -> .Busy.
- stripping old perms is what makes reusing the old range safe.

stale ptrs:
- fs lib: NoPermission on a cached ptr = stale -> re-resolve path once, retry. second failure is a real error.
- watchers can hit this too (window between transfer_perm and Notify).
- disk is never mapped -> stale access = error return, never a crash.
- shared mapped RAM shrink (wayland F_SEAL_SHRINK / SIGBUS problem) -> solved by fault upcall.

fault upcall (needed anyway):
- page fault -> kernel saves regs into user save area, enters the process at a registered handler with reason Fault (+ addr, read/write), like the Resume path.
- needed for windows SEH / guard pages / stack growth, and is the userland way to probe perms.

perm granter:
- a perm granting daemon outside the kernel (policy = code, no code in kernel). start single = adam, split later (fs/gpu/net granters) by delegating ranges.
- dynamic: process writes request into a page shared with the granter + Notify. granter prot_domain_edit Add + Notify back.
- control path only, data path never touches it. granter dies -> no new perms, old ones keep working.

free space allocation:
- no on-disk free map. boot scan from root (only dirs read, file headers live in parent entries): referenced = used, rest free.
- one extent allocator lib used at both levels: sorted array of free {start, len} in RAM, first fit, coalesce on free, byte units (8 aligned) so small files can share a block.
- granter holds all free disk after the scan, grants exactly the size asked.
- spawn grants 0 disk. process fs lib lazily requests whatever size it wants on first write; batching requests is the process's business.
- clean exit returns free ranges to the granter. crash leaks until next boot scan.
- if Y moves a file inside X's arena, X's allocator still thinks the old range is used -> leak until boot scan (v1 ok).
- kernel buddy not reused (intrusive free nodes in free memory, pow2 rounding).

still OPEN: small files (~50% < 2KB) vs block granular perms. allocator perf on a heavily fragmented granter list (first fit is linear) -> add a size index only if measured slow.
