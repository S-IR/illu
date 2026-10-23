FS LIB: CONTEXT

What exists now:
- lib/nvme: pure driver, no globals (init.odin, device.odin, io.odin, nvme.odin, nvme-regs.odin).
- lib/diskhelpers: DiskDriver union {NvmeDisk{dev nvme.Device, queue nvme.Queue}} BY VALUE (no pointers), Disk{driver, blockCount, base, blockSize}, disk_new(driver, blockSize, blockCount, base) -> (disk, used size). Planned cleanup: return u64 + ok instead of int -1, drop the duplicate overflow check (division check + overflow_mul both present).
- adam owns all global state: the disks array (+ lock) in adam/drivers.odin, nextMadeUpAddr in adam/gs. adam_dispatch_pci_device calls nvme.init, queue_pair_create, queue_init, then diskhelpers.disk_new, then appends. The NvmeDisk copy inside the disks array is the ONLY live copy (admin tail/head/phase/cid/nextQid + queue state are live hw state).
- Tested in QEMU (.zed/debug.sh, image diskimg/nvme.img 64MiB, 512B blocks): init, admin cmds, disk registered at base 2^52.
Everything below is decided unless it is marked OPEN.

PRINCIPLES (general rules: claude-memory.md DESIGN RULES)
- lib/fs = meta lib, MAY issue disk commands itself (detect_fses reads GPT + sniffs partitions).
  Format libs (lib/gpt, lib/ntfs, lib/ext4) stay pure: bytes in, parsed data out, no IO. lib/ifs is NOT pure: it MAY alloc DMA and issue disk IO itself.
- Seam = BlockRange{block, count}: every fs (this one, later ext4...) outputs it, every hw lib takes it. N fs + M hw, not N*M.
- Queues are shared between processes: no queue-wide wait_all.
- Single-phase pieces: no multi-phase ops inside the lib. The caller composes create/delete/move/copy/resize from pieces.
- No implicit work: a missing parent gives .NotFound, and the caller creates parents itself.
- A std-like file API (win32 CreateFile/ReadFile) is a separate lib on top.
- shared.assert must call runtime.assert: a bare assert inside package shared recurses into itself.
- RAM-disk tests are extra to modelcheck.

ERRORS
shared.Error (lib/shared/error.odin). Exists: None, InvalidAPICall, OutOfMemory, Timeout, Corrupt, NotFound, FsDiskFull. Planned for ifs, not in the enum yet: DirFull, OutOfRange, DiskFileFull, NameAlreadyExists.

ON-DISK LAYOUT
- Block 0 = Superblock{magic u64 = 0x5346_495f_554c_4c49, root Slot} (24B).
- Slot{offset u64, cap u64} = 16B, in bytes, block aligned, cap > 0. Zero slot = free.
- Every file (dirs too) is one contiguous extent described by a Slot in its parent dir.
- The lib knows only slots. Type-specific metadata (windows attrs, times, byte size) is the first part of the file's data, written by that type's user lib.
- dir = DirHeader{count u64, reserved u64 = 0} 16B + Slot[]. Slots never straddle a block.
  slot 0 = the dir's name file. The name file is a NORMAL file: the allocator places its extent like any file's, with no special position (never "right after the dir"). Read/written like any file, only its content format is special.
  count = last used slot + 1. The last slot is reserved for the chunk link.
- Names decide types: dir = name ends with an unescaped '/'. '\' escapes the next byte.
  Names are UTF-8 (WTF-8 in the win layer) and case sensitive. '|' is forbidden in user names.
- Dirs have a fixed cap and NEVER move, because other processes' private pathmaps hold the dir offset.
  When a dir is full: make a new dir and write its slot + the name "|/" into the reserved last slot (chunk link).
  A second "|/" in one chunk = .Corrupt.
- File chunks are a naming convention only ("foo.txt|1", "foo.txt|2" siblings). Files are normally realloc'd on resize, never chunked by the lib.

NAME FILE (dir slot 0)
- [NameFileHeader{refLen, heapOffset} 16B][refs NameRef{slotIdx, nameOffset} 16B each, grow up ->] free [<- heap grows down to file end]
- refs are SORTED by raw UTF-8 bytes, strict, no dups. Why: prefix/wildcard lookups (FindFirstFile "a*") can't use the hash map, and NTFS enumerates sorted.
- heap record = NameRecord #packed{nameLen u64} + name bytes, no padding (packed = unaligned-safe).
- nameOffset is ABSOLUTE in the file, because heap start moves as it grows down.
- empty file = header {0, file len}. All-zero file = .Corrupt (catches TRIMmed / never-written extents).
  So format MUST write the header. (The old format wrote a zeroed name file, so format then mount gave .Corrupt. Don't repeat that.)
- insert(slotIdx, name): .NameAlreadyExists, or .DiskFileFull (caller reallocs a bigger file and retries). Empty name = .InvalidAPICall.
- remove(name) -> slotIdx / .NotFound: closes the heap hole, patches offsets, zeroes freed bytes.
- parse validates everything and returns .Corrupt. Never crash or loop on garbage.

ATOMICITY / DURABILITY
- RAM edits happen in place. Disk writes of multi-block structures are CoW: write the new extent, flush, swap the 16B slot (one block = atomic), free the old only after the swap is persisted.
- Slot edit: the caller writes block (16 + 16*slotIdx)/blockSize, plus block 0 if count changed. Either order is crash safe (zero slot = free, slot past count = leak).
- create: slot first, then name. delete: name first, then slot. A crash leaks, never corrupts (with flushes between phases).
- Flush is the caller's piece, never automatic. On nvme: wait the writes, queue_flush, wait the flush.

OP COMPOSITION (caller side)
- create = read parent dir + name file, alloc, slot edit, write dir, wait, name edit, write name file (CoW), wait, pathmap insert.
- delete = name first, wait, slot, wait, free.
- resize = alloc new + copy + delete old + update slot. move = cross-dir slot move + names. copy = alloc + copy data + create.

PATHMAP (per process, private)
- map[u128 = xxh3_128(path)]PathEntry{offset, cap, slotIdx, dir = slot of the chunk holding the entry}.
- 2026-10-18: LAZY by default. No full-tree fill per process. A lookup walks from the nearest cached ancestor (or root), reads the missing dirs + name files, and inserts the dirs.
  No LRU, no eviction (rejected as overengineering). A remove fn exists for processes that want to shrink it. Growing huge is the process's problem.
  Optional later: seeding (copy another process's map to speed up startup).
- Inserted dirs include chunk keys. Chunks flatten: a "|/" chunk is read under the SAME dir path,
  and each link is also inserted under key path + "|k/" (k = chunk number 1..) so chunk k is found by hash.
- Files enter the pathmap on open and leave on close (insert/remove pieces).
- Root "/" must be in the map (the old code never inserted it).
- MOUNT = superblock + FULL SCAN for the allocator: walk every dir and its slots to find every used extent and build the free list (no on-disk free map). It does NOT fill the pathmap. Done by the allocator owner (adam for now), once at boot, batched per tree level (all dirs of a level, then all their name files).
  It can start from ANY dir (path + slot). It collects used extents (superblock, every dir, name file, file) for the allocator. An on-disk cache of this may come later.
- Known: one corrupt dir or name file aborts the whole scan. Deal with it when fs security starts.
- path_split on the last unescaped '/'. Lookups must search every chunk of a chunked dir.

RESOLVE
- resolve(pathmap, blockSize, []FileRange{path, offset, len}, []BlockRange) -> (resolved, err).
  offset/len are bytes inside the file, block aligned (shared.assert), and must fit entry.cap else .OutOfRange. err concerns files[resolved].
- The caller then does nvme.queue_io(&q, op, blocks[i].block, bufs, prpList), with total bufs = count * lbaSize.

DISK ALLOCATOR
- No on-disk free map: the boot scan rebuilds it (referenced = used, rest free).
- Range based (2026-10-19): DiskAllocator{free [dynamic]Extent, range Extent}. disk_allocator_init(range, used) -> (DiskAllocator, Error) builds free gaps inside range from the used list (.Corrupt on overlap or out of range). Separate allocators can own separate ranges.
- Sorted, first fit, free = binary search + 4-case merge. ifs uses range {1, partBlocks-1} (block 0 = superblock stays outside).
- A process gets big extents rarely and allocates locally. For now adam grants all. Policy (quotas, popups) = granter daemon later.

PARALLELISM (decided, not built)
- Data IO is lock-free. One lock per file (dirs are files), only for metadata edits (slot swap + name edits).
- Locks live in a separate shared hashed lock map. Pathmaps stay private.
- lock = LEASE: a u64 word holds the expiry TSC. acquire = CAS when 0 or expired, else wait_on(&word, seen, deadline = seen). unlock = store 0. A dead holder just expires.
- Each lock has a version, bumped after edits. Others wait_on/compare it for staleness.
- Dir RAM sharing: dirs loaded on demand, each dir page aligned and >= 1 page. Lock map entry = {key, lock, version, ram}. Grants are push-only (prot_domain_edit), so the granter (adam for now) loads + grants.

PARKED / OPEN
- Stale file offsets after CoW/resize in other processes' pathmaps (use-after-free).
  Proposal: file id = slot address (dir.offset + 16 + 16*slotIdx, stable), lock map keyed by it, resolve reads the current slot from shared dir RAM.
- Dir RAM lifetime / dangling ram ptr in the lock map.
- The file byte length is not stored (Slot = offset, cap). Fine for basic CRUD, a real file API needs it (type lib header).
- Small files (~50% < 2KB) vs block-granular perms.

DISK SECURITY (see contracts.md, hardware-assumptions.md)
- No IOMMU, no LBA perms, no SR-IOV assumed. The kernel stays dumb and knows no device or fs.
- Disk perms = memory perms: disk window = fake phys DISK_BASE + lba << blockShift, granted/split via prot_domain_edit.
- Device commands are mediated by generic kernel contracts written by adam (contracts.md). Rejected: kernel hw knowledge, fully-trusted daemon, per-IO kernel round trip, bounce buffers.

NVME LIB FACTS (lib/nvme, kept)
- queue_io(q, op .Read/.Write, startBlock, bufs [][]u8, prpList []u64) -> (Pending, shared.Error).
  bufs[0] 4B aligned, the others page aligned. Every buf but the last ends on a page boundary. Total is a multiple of lbaSize and <= q.maxTransfer.
  len(prpList) == prp_list_len(bufs), page aligned.
- maxTransfer = min(MDTS, 65536 * lbaSize), never 0.
- queue_flush(q) -> (Pending, shared.Error). wait(pending, deadline TSC; max(u64) = no deadline). .Timeout = still in flight, wait again. .NvmeQueueFull: wait your own pendings, then retry.
- NvmeQueueFull has 2 causes (io.odin:57/59): inFlight == depth-1 (any completion frees it) or no Free cid (a cid only frees in its OWNER's wait()). So never block inside submit waiting for a slot: a caller holding all cids as unwaited Done would deadlock. Waiting a finished pending twice trips the assert states[cid] != .Free.
- lib/nvme init.odin: init(pciDevice) -> (Device, blockCount, shared.Error). queue_pair_create(^Device, msixRow u16) -> QueueInfo (CQ created with IEN, IV = msixRow), controller_disable.
- Interrupts: adam programs MSI-X (pci.msix_table) between nvme.init and queue_pair_create, row NVME_MSIX_ROW 0 -> vector NVME_VECTOR 0x20 on the current core. See interrupts-context.md. dma_pages moved to lib/alloc (userspace only, `when !KERNEL_BUILD`, @(require_results)). MDTS read at identify byte 77. Only adam calls init/admin (trusted owner); other processes only get queue pairs.
- device.odin: Device struct, admin_execute_command (sync on purpose: admin cmds are rare and dependent; no timeout, returns .NvmeControllerFatal on CSTS.CFS). ADMIN_QUEUE_DEPTH 2 (sync => 1 in flight; spec max 4096, open).
- Errors: shared.Error (lib/shared/error.odin), nvme block 0x100 (Nvme* prefix).
- I/O queue depth = CAP.mqes + 1 (no software cap). queue_init(info) -> (Queue, shared.Error), allocates states slice.

GPT + FS DETECTION (state 2026-10-18: written, first boot run + verified)
- Goal: per disk, detect partitions -> flat list of Fs so ntfs/ext4/ifs drivers plug in later.
- lib/fs/parse.odin:
  detect_fses(disk ^Disk, diskIdx int) -> ([dynamic]Fs, shared.Error). Fs #all_or_none {diskIdx, start, len, type FsType{Ifs, Ntfs, Ext4}}.
  Reads GPT header (LBA 1), entry array (PRP list when needed), gpt.parse_entries, then ONE DMA PAGE PER PARTITION from firstLba (covers ext4 magic at 1080), submit all, wait_all, sniff ntfs.is / ext4.is / ifs.is. No match = skip. Detection only, no mount.
- lib/diskhelpers:
  disk_io(disk, op nvme.IoOpcode, block, buf, prpList = nil) -> (DiskPending, Error): generic wrapper. .Flush needs block 0, empty buf, empty prpList -> nvme.queue_flush. .Read/.Write -> nvme.queue_io.
  disk_submit(disk, dps ^[dynamic]DiskPending, op, block, buf, prpList = nil) -> Error: disk_io + append; on .NvmeQueueFull with own pendings: wait_all, clear (also on wait error, so nothing is waited twice), retry; else return the error. On error the CALLER must wait_all(dps[:]) before returning (device may still DMA into buffers the caller's defers free).
  wait(dp), wait_all(dps []DiskPending) (slice, does not clear; caller clears).
- lib/fs/format.odin: gpt_format(disk, entries []gpt.PartitionEntry, entryCount u32, diskGuid) -> Error.
  header_new, meta buffers [gpt.MetaBlock]{Mbr, PrimaryHeader, BackupHeader} one block each in one dma_pages(len(MetaBlock)), entry array buffer + PRP list,
  protective_mbr, entries_write -> partitionEntryArrayCrc32, headerCrc32 = crc32(header bytes) inline (field must be 0 when hashing),
  backup = header with myLba/alternateLba swapped, partitionEntryLba = lastUsableLba + 1, headerCrc32 zeroed then rehashed, assert backup array ends right before backup header.
  5 writes via disk_submit (LBA 0, LBA 1, array at 2, backup array, backup header), wait_all, .Flush, wait.
- Sniff libs (pure, is(partitionStart []byte) -> bool, shared.assert on length): lib/ntfs "NTFS    " @3, lib/ext4 u16le 0xEF53 @1080, lib/ifs u64le 0x5346_495f_554c_4c49 @0.
- lib/gpt (pure): parse.odin (was gpt.odin): parse_header(data) (myLba must be 1, cannot parse the backup header), parse_entries(h, data) -> [dynamic]Partition, header_new, entries_write. mbr.odin: protective_mbr (finished; endingChs always 0xFFFFFF, fine). Readers do not check the protective MBR (GPT header + CRC decide).
- adam/main.odin (debug test): after the pci loop, per disk: print disk, detect_fses; on .GptNotGpt -> gpt_format(1 MS basic data partition 2048 .. blockCount-2048, 128 entries, fixed test guids), detect again; 0 fses -> ifs format, detect again; every Ifs fs -> ifs.mount. Runs to alive_loop.
- Verify on host after a run (quit qemu first): fdisk -l diskimg/nvme.img (sgdisk not installed).

IFS FORMAT (DONE, boot verified 2026-10-18)
- Default caps (user chosen): root dir cap = PAGE_SIZE, name file cap = PAGE_SIZE.
- format(disk, partStart, partBlocks) -> (DiskAllocator, Error): writes root dir (count 1, slot 0 = name file) + name file header {0, cap}, flush, then superblock (block 0, root Slot), flush. Extents from the allocator.
- WATCH: Pending holds ^Queue inside the disks.v dynamic array -> dangling if the array grows while pendings live.
- Open nvme questions: ADMIN_QUEUE_DEPTH 2 vs spec max 4096; lbads 9..12 still enforced.
- adam stack is 1 MiB (was 16 KiB: fmt.tprintln(disk) overflowed it in a debug build).

IFS MOUNT (DONE, boot verified 2026-10-23): see claude-memory.md CURRENT WORK.

FREESTANDING NOTES
- fmt has no print/println on freestanding (fmt_os.odin excluded). Use core:log: adam sets context.logger = runtime.Logger{adam_logger_proc, nil, .Debug, {.Level, .Short_File_Path}}; the proc calls syscalls.syscall_debug_print_userspace(text) (value param now defaults to 0).
- log/tprint allocate from context.temp_allocator. The user added free for it (2026-10-19). Default: temp allocs use context.temp_allocator, no delete needed.
- No checked int casts in Odin; use intrinsics overflow_add/sub/mul or compare against the target max before casting.

MILESTONE
- Basic CRUD (create, write, read back, delete, rescan) running in adam on the real nvme queue. Then modelcheck proofs.
- Model to prove: 2 procs, 3-slot dir, name file, allocator, in-flight writes, crash transition.
  Invariants: no races, no corruption, no half writes, no double alloc, no use-after-free, durability after flush+ack,
  readers see old or new, tree stays a tree, crash leaks reclaimed by scan, no deadlock / lease acquired, garbage-proof parse.

PERMS IDEAS (from the old fs-design.md, not built, still valid)
- transfer_perm(oldPtr, oldSize, newPtr, newSize) syscall (generic, knows no fs): for resize/move. Caller needs W on both ranges, no overlap. Kernel scans every domain: resource == old range -> new range; inside old -> shifted + clipped (empty = removed); containing old (space owner) -> untouched; straddling an edge -> reject. Mapped: unmap old, map new, tlb shootdown. Disk window: list rewrite only. Live loan/pin on old -> .Busy. Stripping old perms is what makes reusing the old range safe.
- Stale cached location in a pathmap: NoPermission = stale -> re-resolve once, retry; second failure is real. Disk is never mapped -> stale access = error, never a crash.
- Fault upcall: page fault -> kernel saves regs to a user save area, enters the process at a registered handler with reason Fault (+ addr, read/write). Needed for SEH, guard pages, stack growth, perm probing.
- Perm granter: policy daemon outside the kernel (adam for now, split later by delegating ranges). Request via shared page + Notify, granter prot_domain_edit Add + Notify back. Control path only. Granter dies -> no new perms, old ones keep working.
- Unverified hw security: MSI-X vector per CQ grantable to a client; CQE posted only after data DMA is done (PCIe ordering); xHCI interrupter count on consumer controllers + setup TRB cross-device harm.
- Revoke DoS: a client keeps re-pinning a shared target. Fix: revoker first pulls the client's slot + doorbell grants.
