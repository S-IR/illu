# ifs context (terse)

## On disk
- Block 0: Superblock{magic, root Slot}.
- Slot{offset, cap}: bytes, block aligned. {} = free.
- Every file is one extent, described by a Slot in its parent dir.
- Dirs are files. Name files are files. Same create/read/write fns for all of them.
- Dir = DirHeader{count, reserved=0} + Slot[]. Dirs never move.
- Name file (optional): by convention at dir slot 0.
  - Layout: NameFileHeader{refLen, heapOffset} + sorted NameRef{slotIdx, nameOffset}, then a name heap at the end, growing down.
  - Parsers (mount, path_lookup) try slot 0 as a name file. On .Corrupt they skip it (the dir counts as unnamed).
- A name ending in an unescaped '/' is a dir.

## Rules (user)
- Error returned = all other outputs are garbage. Fns taking dps leave nothing in flight on error.
- The lib waits only where correctness needs it (read results, write barriers). Every other wait is the caller's.
- Barrier = FUA write + wait. Lib pieces never flush.
- Atomic: only the name file is CoW (new extent, write, barrier, swap slot 0, barrier, free old). Dirs and file data are written in place.
- The caller writes all data, dir content included.
- ifs holds both the pieces and the composed ops. Every piece is public.
- Batched create, one parent dir per call. The new name file gets the same cap as the old one; full = .FsDiskFileFull.
- Mount = full scan for the allocator, batched per tree level. Pathmap is lazy, no eviction.

## Code state (type-checks, NOT boot tested)
- diskhelpers.disk_io is the only IO fn. files_io (ifs/io.odin) drains dps on error.
- dir_parse: the slot 0 zero check is gone. dirs_read/mount/path_lookup skip a slot 0 that fails as a name file.
- path_lookup("/") on a cache miss returns .NotFound (root must be inserted by adam).
- ifs/ops.odin: create + create_named, written by Claude. User verdict: far too long, unacceptable. Redo it.
  - Known bug: create_named waits with `wait_all or_return` while a drain defer exists, so a wait error waits the same pendings twice and trips the assert at nvme/io.odin:102.
  - Bloat sources:
    - The name file is made with create (slot k), which costs an extra clear write + wait.
    - The pre-check of names on a temp copy exists only to avoid leaking slots on dup/full.
- Boot test still pending (format, mount, and nvme paths all changed).
