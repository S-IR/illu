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

## Code state
- See claude-memory.md "ifs API".
