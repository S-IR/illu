CLAUDE MEMORY (moved here from the hidden ~/.claude memory dir 2026-10-18; all Claude context for this project lives in root .md files)

WORK RULES
- Scope: only small, minimal changes unless the user says verbatim "YES I WANT YOU TO RUN AROUND THE CODEBASE AND I ACCEPT THE RISK THAT YOU MIGHT RUIN IT". Without it: change only the exact lines asked, no deleting/restoring/moving files, stash or reset on my own reading. Report every change. (2026-10-08/09: unrequested rewrites wrecked two days of work.)
- Hand-typed steps: don't edit project files by default. One explained step per reply, then wait for "okay next". Edit only when the user explicitly says so for that task; the permission doesn't carry over.
- Words only: no code in chat (no snippets, pseudo-code, diffs). Exception: spec-defined code (GPT/UEFI, NVMe, AHCI, NTFS, ext4, PE, ACPI structs/constants/offsets), exact to the spec. The user may lift it for one reply ("whats the code").
- Ultra terse: a few short lines. One point, one recommendation, one question max. No walls of text.
- No invented design: minimal = minimal. No callbacks/proc-ptr args, state machines, extra params or new structs (check whether an existing struct already holds the data). Ask before any design choice.
- No inferred rejections: a bare "no" = ask which part. Never widen it into a category.
- Verify before showing: think it through mentally. NO scratchpad temp files or test images. Reading real repo files and Odin core source is fine.
- Compiling (2026-10-23): Claude MAY compile (commands that terminate, e.g. odin check / odin build to obj). Never run qemu: it never ends and is slow; the user runs it.
- Never call SendFeedback (banned 2026-10-04).
- Temp allocs use context.temp_allocator by default (2026-10-19). Do not push context.allocator + delete for scratch data.
- Odin style APIs (2026-10-19): fns RETURN structs (value, err). No C-style "pass a ptr and fill it" params.
- Never mention unused imports (2026-10-19): they compile away, the user does not care.
- Insert spots (2026-10-23): when telling the user to add code to existing code, give file:line (grep/read the current file first).
- Context files: all Claude memory/context for this project goes in .md files in the repo root. Never write hidden memory files.
- Commit reminder (2026-10-23): when a task is done and ready to git commit, remind the user to run `zed prod.sh` too.

DESIGN RULES
- Expose to userland: the kernel does only security-sensitive work. Routing, policy, tuning and convenience are userland's job. Foot-guns allowed.
- Expose hardware: device libs (nvme, sata) are public at full capability (flush, FUA, write zeroes, trim...). Generic wrappers (lib/diskhelpers) are optional layers on top, never replacements.
- Async hardware: submit everything independent, wait once per phase / tree level. No sync-per-item APIs, no 1-element batch loops. Each caller waits only its own pendings.
- No made-up limits: only real hw/spec limits (MDTS, MQES, MPSMAX...). Flag any pick that limits nothing and let the user choose. User-chosen defaults are ok (ifs caps = PAGE_SIZE).
- Assert before API error: invalid API usage = `if !shared.assert(cond) do return ..., .InvalidAPICall`, both always. Internal state invariants = plain assert.
- Shared error enum: one shared.Error enum u64 (lib/shared/error.odin). 0x000 common, 0x100 nvme, 0x200 gpt, 0x300 fs (FsDiskFull). Each new lib takes the next 0x100 block. Compare with `.None`.
- Prove first: lib/modelcheck (TLA+-like BFS) is the test standard (example: kernel/pmm/pmm_model_test.odin). The fs property list is in fs-context.md MILESTONE.
- Daemon = normal process: no dedicated core, no special kernel call path.
- Disk security rejections (2026-10-04), exact variants only: kernel device knowledge (generic userland-described kernel checks are ok), a daemon fully trusted with RAM, a per-IO kernel round trip, bounce buffers, the masked_write pairing rule. The fs daemon idea itself is still OPEN. No IOMMU, no SR-IOV, no nvme LBA perms assumed.

IFS FACTS
- The name file is a NORMAL file whose Slot is slot 0 of its dir. Its extent comes from the allocator like any file's. Never assume a position ("right after the dir" was wrong).
- lib/ifs may alloc DMA and do IO (2026-10-18). gpt/ntfs/ext4 stay pure.
- Pathmap is lazy, no LRU, no eviction. Mount = full scan for the allocator only (see fs-context.md PATHMAP).

CURRENT WORK (2026-10-23)
- Done + boot verified: MSI-X, GPT format + detect, lib/diskhelpers split, ifs format, ifs mount (second boot: detect finds Ifs, mount returns .None).
- ifs mount (lib/ifs/mount.odin): superblock, BFS per tree level (all dirs, then all their name files), usedBlocks guard vs cycles, classify child dirs via name file, return disk_allocator_init({1, partBlocks-1}, used[:]).
  - Two grow-only DMA buffers reused across levels (dirsDma, namesDma). `level` is cleared and refilled with child dirs after the name read (bufs/nameBufs hold the data, level no longer read).
  - Read pattern: prp, readErr := disk_read_batch (no or_return), defer free prp, wait_all ALWAYS, then readErr, then waitErr.
- lib/ifs/file.odin: NameRef, NameRecord #packed, ref_name(buf, ref) (validated refs only), name_file_parse(buf) -> (refs view, err) (bounds chain makes overflow impossible, .Corrupt on garbage, no shared.assert on disk data), is_dir_name (trailing '/' with even count of preceding '\'), CHUNK_LINK "|/".
- Not yet tested: format-then-mount in the same boot (fresh disk image). mount result (diskAlloc.free) not printed/checked.
- Not checked by parser (user may decide): overlapping heap records, duplicate slotIdx. Orphan slots (slot without name, crash leak) are counted used, not reclaimed.
- NEXT: basic CRUD (fs-context.md MILESTONE).

DETOUR: LOGGING (2026-10-23, design agreed, nothing built)
- Events with severity. Prod keeps errors + rare milestone events (boot stage, fs mounted). Verbose = debug only, gated by compile-time `when` (zero cost in prod).
- Per-process ring buffer in memory, written by the process's own log proc. A viewer is a normal program granted read perms on the rings (no daemon, authority = memory perms). Persist: survive warm reboot region or a program copies rings to disk (open).
- Binary fixed-size records: {tsc, severity, shared.Error, #caller_location file:line, few u64 args}. Formatting happens in the viewer. No struct dumps.
- Error origin tracing: record where an error first becomes non-.None + each or_return hop.
- Crash dump: NO kernel part (2026-10-23). The process logs its own fault from the .Fault entry + saveArea. The kernel never touches log rings.
- FAULT FORWARDING (built + boot verified 2026-10-23: #PF nil write -> adam .Fault prints vector/rip/cr2, grant_exit): grant_fault in kernel/grant.odin, adam _start fault branch in asm_helpers/adam_helpers.asm. User fault -> if saveArea.control.restoring is set (handler/restore still running) kill the grant, else store the frame like grant_preempt, write vector/error/cr2 into the 3 spare u64s of UserSaveArea (offset 168), enter entry with .Fault. App logs, then fixes + restores itself or grant_exit. Kernel faults still halt. Today: kernel/idt.odin user fault prints + grant_exit. Handler stack = the faulting rsp from saveArea minus red zone (stack overflow -> killed). Separate fault stack only when stack growth is built.
- syscall_debug_print (serial) stays for debug builds only.
- Decided 2026-10-23: drop context.logger and core:log, use our own log proc. No strings stored in records, all fields numeric, the viewer decodes them with normal code.
- Severity = syslog RFC 5424 levels 0..7 (Emergency..Debug), u8 enum. Milestones = Notice.
- Record file field = u64 address of #caller_location file_path bytes (rodata, zero cost). #hash cannot take the caller path (needs a constant), Odin has no return-address intrinsic.
- DONE + boot verified 2026-10-23: lib/log (Severity, Record 64B with u8 seq, Ring, ring_push, write($severity, err, ..u64 args max 4, loc)), adam ring (adamLog 1024 records, adamLogPrinted), adam_log_dump in adam/debug.odin (serial viewer), all adam prints converted to log.write, context.logger removed, assert handler + .Fault log + dump.
- NEXT for the detour: boot test, then error origin tracing, enum names in the dump (core:reflect), viewer perms on the ring.
