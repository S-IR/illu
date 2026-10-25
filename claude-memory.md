# claude memory (terse)

## Work rules (user)
- No code in files unless explicitly asked for that task. Show code in chat with file:line insert spots.
- Ultra terse. No invented design or premature abstraction: build the raw thing first, extract helpers only once repetition shows up.
- Claude may compile (`odin check <pkg> -vet-shadowing -target:freestanding_amd64_sysv -no-entry-point`). Never run qemu; the user runs `.zed/debug.sh`.
- Asserts must print like stock Odin: `file(line:col) prefix: message`. The user wants no log-ring prints for now (the logs are useless to them).

## ifs API (2026-10-25, boot verified)
ops.odin was deleted. The whole API is these pieces:
- `files_io(disk, partStart, op, slots, offsets, bufs, fua, dps)`: batched async read/write of any file (data, dir, name file). Never waits. Drains dps on error.
- `slots_read(disk, partStart, slots, dps)`: allocs aligned bufs (temp allocator) and reads them.
- `dirs_read(disk, partStart, partBlocks, dirSlots)`: reads dirs, then their slot 0 name files. Waits.
- `disk_alloc` / `disk_free` (blocks relative to the partition; Slot.offset = block * blockSize).
- `dir_parse`, `dir_slot_set`, `dir_slot_clear` (RAM only).
- `name_insert`, `name_remove`, `name_find`, `name_file_parse` (RAM only).
- `path_lookup(pathmap, ...)`: lazy, reads from disk on a miss. The root "/" must be inserted by the caller.
- Create = disk_alloc + dir_slot_set + name_insert, then files_io the data + dir + name file.
- Delete = name_remove + dir_slot_clear, files_io dir + name file, wait, THEN disk_free (freeing earlier lets a reuse hit disk before the cleared slot does -> corruption on crash).
- No rollback on error: an error means the touched bufs and the allocator are garbage.

## Test state
- `ifs_test` in adam/main.odin: create /hello.txt, batched write (data + root dir + name file), read back + compare, path_lookup from disk, delete. Passes on boot.
- The name file is written in place in the test, not CoW.
- fs-context.md "Code state" section is stale (talks about ops.odin). This file wins.

## Other fixes this session
- kernel/syscall.odin DebugPrint prints only `dbg: <label>` now (value dropped). Callers that passed a value (alive loop, ntdll_immitator ExitProcess) lose it.
- lib/alloc/alloc.odin heap_free: the `oldSize > 0` assert is kernel-only (`when KERNEL_BUILD`). Userspace free ignores the size; Dynamic_Arena free_all frees out-band allocs with size 0.
- adam assert handler prints the Odin-style line via fmt.bprintf, then grant_exit.

## Next
- Build helpers on top of the pieces for repeated work (read a whole file, write a file, create/delete by path). Derive them from what ifs_test repeats; keep them minimal.
