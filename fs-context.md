FS LIB: CONTEXT FOR THE REWRITE FROM SCRATCH (written 2026-10-09)

The previous fs lib was deleted on 2026-10-09. adam/fs is gone too. What exists now:
- lib/nvme: pure driver, no globals (init.odin, device.odin, io.odin, nvme.odin, nvme-regs.odin).
- lib/fs/fs.odin: DiskDriver union {NvmeDisk{dev nvme.Device, queue nvme.Queue}} BY VALUE (no pointers), Disk{driver, blockCount, base, blockSize}, disk_new(driver, blockSize, blockCount, base) -> (disk, used size). Planned cleanup: return u64 + ok instead of int -1, drop the duplicate overflow check (division check + overflow_mul both present).
- adam owns all global state: the disks array (+ lock) in adam/drivers.odin, nextMadeUpAddr in adam/gs. adam_dispatch_pci_device calls nvme.init, queue_pair_create, queue_init, then fs.disk_new, then appends. The NvmeDisk copy inside the disks array is the ONLY live copy (admin tail/head/phase/cid/nextQid + queue state are live hw state).
- Tested working in QEMU 2026-10-09 (debug.sh): init, admin cmds, disk registered at base 2^52. prod.sh lacks the nvme drive/device lines. The nvme changes of 2026-10-12 (no made-up limits, selftest removed) are NOT compiled/tested yet.
Everything below is decided unless it is marked OPEN.

PRINCIPLES
- 2026-10-10: lib/fs = meta lib, MAY issue disk commands itself (detect_fses reads GPT + sniffs partitions).
  Format libs (lib/gpt, lib/ifs, lib/ntfs, lib/ext4) stay pure: bytes in, parsed data out, no IO.
- The caller sends those straight to the device lib (lib/nvme now, a sata lib later).
  2026-10-13: per-hardware APIs are primary and always public. Generic convenience wrappers (e.g. read_from_disk/DiskPending) are OK on top for callers that do not care about the hw, but must never replace or hide the per-hw path.
- Seam = BlockRange{block, count}: every fs (this one, later ext4...) outputs it, every hw lib takes it. N fs + M hw, not N*M.
- Expose hardware: the nvme lib is public at full capability (flush, FUA, write zeroes, trim...). Never hide it, never treat the disk like a potato.
- Async hardware: submit everything independent, wait once, batched per phase / per tree level.
  Never sync submit+wait per item. Never call a batch API with 1-element batches in a loop.
  Each caller waits only its own pendings (queues are shared between processes, no queue-wide wait_all).
- Single-phase pieces: no multi-phase ops inside the lib. The caller composes create/delete/move/copy/resize from pieces.
- No implicit work: a missing parent gives .NotFound, and the caller creates parents itself.
- A std-like file API (win32 CreateFile/ReadFile) is a separate lib on top.
- Invalid API usage = assert AND return error, both, always: `if !shared.api_check(cond) do return ..., .InvalidAPICall`.
- No made-up limits. Only real hardware limits (MDTS, MQES, ...). Any unavoidable software cap must be flagged loudly.
- Prove first: lib/modelcheck (TLA+-like BFS over states) is the test standard. RAM-disk tests are extra.

ERRORS (last set)
None, InvalidAPICall, NotFound, DirFull, OutOfRange, DiskFull, DiskFileFull, Corrupt, OutOfMemory, NameAlreadyExists.

ON-DISK LAYOUT
- Block 0 = Superblock{magic u64 = 0x5346_495f_554c_4c49, root Slot} (24B).
- Slot{offset u64, cap u64} = 16B, in bytes, block aligned, cap > 0. Zero slot = free.
- Every file (dirs too) is one contiguous extent described by a Slot in its parent dir.
- The lib knows only slots. Type-specific metadata (windows attrs, times, byte size) is the first part of the file's data, written by that type's user lib.
- dir = DirHeader{count u64, reserved u64 = 0} 16B + Slot[]. Slots never straddle a block.
  slot 0 = the dir's name file. count = last used slot + 1. The last slot is reserved for the chunk link.
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
- The init scan inserts ONLY dirs + chunk keys. Chunks flatten: a "|/" chunk is scanned under the SAME dir path,
  and each link is also inserted under key path + "|k/" (k = chunk number 1..) so chunk k is found by hash.
- Files only get marked used for the allocator. Files enter the pathmap on open and leave on close (insert/remove pieces).
- Root "/" must be in the map (the old code never inserted it).
- The scan starts from ANY dir (path + slot), not only root. It is batched per tree level: read all dirs of a level, then all their name files.
- The scan collects used extents (superblock, every dir, name file, file) for the allocator.
- OPEN: how the batched scan hands reads to the caller with no IO inside the lib. A scan_begin/scan_next state machine was built and rejected. Ask the user before designing it.
- Known: one corrupt dir or name file aborts the whole scan. Deal with it when fs security starts.
- path_split on the last unescaped '/'. Lookups must search every chunk of a chunked dir.

RESOLVE
- resolve(pathmap, blockSize, []FileRange{path, offset, len}, []BlockRange) -> (resolved, err).
  offset/len are bytes inside the file, block aligned (api_check), and must fit entry.cap else .OutOfRange. err concerns files[resolved].
- The caller then does nvme.queue_io(&q, op, blocks[i].block, bufs, prpList), with total bufs = count * lbaSize.

DISK ALLOCATOR
- No on-disk free map: the boot scan rebuilds it (referenced = used, rest free).
- Sorted [dynamic]Extent{block, count}, first fit, free = binary search + 4-case merge, init builds free gaps from the used list (.Corrupt on overlap or out of disk).
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

DISK SECURITY (see contracts.md, fs-design.md, hardware-assumptions.md)
- No IOMMU, no LBA perms, no SR-IOV assumed. The kernel stays dumb and knows no device or fs.
- Disk perms = memory perms: disk window = fake phys DISK_BASE + lba << blockShift, granted/split via prot_domain_edit.
- Device commands are mediated by generic kernel contracts written by adam (contracts.md). Rejected: kernel hw knowledge, fully-trusted daemon, per-IO kernel round trip, bounce buffers.

NVME LIB FACTS (lib/nvme, kept)
- queue_io(q, op .Read/.Write, startBlock, bufs [][]u8, prpList []u64) -> (Pending, shared.Error).
  bufs[0] 4B aligned, the others page aligned. Every buf but the last ends on a page boundary. Total is a multiple of lbaSize and <= q.maxTransfer.
  len(prpList) == prp_list_len(bufs), page aligned.
- maxTransfer = min(MDTS, 65536 * lbaSize), never 0.
- queue_flush(q) -> (Pending, shared.Error). wait(pending, deadline TSC; max(u64) = no deadline). .Timeout = still in flight, wait again. .NvmeQueueFull: wait your own pendings, then retry.
- lib/nvme init.odin: init(pciDevice) -> (Device, blockCount, shared.Error). queue_pair_create(^Device) -> QueueInfo, controller_disable, dma_pages. MDTS read at identify byte 77. Only adam calls init/admin (trusted owner); other processes only get queue pairs.
- device.odin: Device struct, admin_execute_command (sync on purpose: admin cmds are rare and dependent; no timeout, returns .NvmeControllerFatal on CSTS.CFS). ADMIN_QUEUE_DEPTH 2 (sync => 1 in flight; spec max 4096, open).
- Errors: shared.Error (lib/shared/error.odin), nvme block 0x100 (Nvme* prefix).
- I/O queue depth = CAP.mqes + 1 (no software cap). queue_init(info) -> (Queue, shared.Error), allocates states slice.

GPT + FS DETECTION (state 2026-10-13)
- Goal: per disk, detect partitions -> flat list of Fs so ntfs/ext4/ifs drivers plug in later.
- lib/fs/parse.odin: detect_fses(disk ^Disk, diskIdx int) -> ([dynamic]Fs, shared.Error). Fs #all_or_none {diskIdx, start, len, type FsType{Ifs, Ntfs, Ext4}}.
  Reads GPT header (LBA 1), entry array (PRP list when needed), gpt.parse_entries, then ONE DMA PAGE PER PARTITION from firstLba (covers ext4 magic at 1080), submit all, wait_all, sniff ntfs.is / ext4.is / ifs.is. No match = skip. Detection only, no mount.
  .NvmeQueueFull with own pendings: wait_all then retry; with none: return the error.
  Also holds DiskPending union {nvme.Pending}, read_from_disk(disk, block, buf, prpList), wait, wait_all.
- Sniff libs (pure, is(partitionStart []byte) -> bool, api_check on length): lib/ntfs "NTFS    " @3, lib/ext4 u16le 0xEF53 @1080, lib/ifs u64le 0x5346_495f_554c_4c49 @0.
- lib/gpt reader: parse_header(data) (myLba must be 1, so it cannot parse the backup header), parse_entries(h, data) -> [dynamic]Partition{typeGuid, firstLba, lastLba}.
- lib/gpt writer (API "A" = small pure procs, caller does IO):
  DONE: Mbr + MbrPartitionRecord structs, protective_mbr(blockCount) -> (Mbr, Error); caller zeroes LBA 0 and copies the 512B Mbr in.
  DONE: header_new(blockCount, blockSize, entryCount, diskGuid) -> (Header, Error): primary header, CRCs 0, entries at LBA 2, entry size 128, min array 16384B (spec), firstUsable = 2 + entryBlocks, lastUsable = blockCount - 2 - entryBlocks.
  DONE: entries_write(h, entries []PartitionEntry, out) -> (crc u32, Error): api_checks used-only entries, in usable range, no overlap; zeroes out, copies, returns crc32 of count*size bytes. Caller sets h.partitionEntryArrayCrc32.
  NEXT: header CRC proc (crc32 of header[:headerSize] with headerCrc32 = 0), backup header (myLba = last LBA, alternateLba = 1, partitionEntryLba = lastUsableLba + 1, own CRC).
  THEN: caller writes LBA 0, LBA 1, primary array, backup array, backup header. Then wire detect_fses into adam (after append to disks.v, pass &disks.v[i], i; store fses in adam), test in QEMU against a GPT disk image (debug.sh).
  WATCH: Pending holds ^Queue inside the disks.v dynamic array -> dangling if the array grows while pendings live.
- Open nvme questions: ADMIN_QUEUE_DEPTH 2 vs spec max 4096; lbads 9..12 still enforced.

FREESTANDING NOTES
- fmt has no print/println on freestanding (fmt_os.odin excluded). Use core:log: adam sets context.logger = runtime.Logger{adam_logger_proc, nil, .Debug, {.Level, .Short_File_Path}}; the proc calls syscalls.syscall_debug_print_userspace(text) (value param now defaults to 0).
- log/tprint allocate from context.temp_allocator = adam heap allocator, never freed.
- No checked int casts in Odin; use intrinsics overflow_add/sub/mul or compare against the target max before casting.

MILESTONE
- Basic CRUD (create, write, read back, delete, rescan) running in adam on the real nvme queue. Then modelcheck proofs.
- Model to prove: 2 procs, 3-slot dir, name file, allocator, in-flight writes, crash transition.
  Invariants: no races, no corruption, no half writes, no double alloc, no use-after-free, durability after flush+ack,
  readers see old or new, tree stays a tree, crash leaks reclaimed by scan, no deadlock / lease acquired, garbage-proof parse.
