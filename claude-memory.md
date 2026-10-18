CLAUDE MEMORY (moved here from the hidden ~/.claude memory dir 2026-10-18; all Claude context for this project lives in root .md files)

WORK RULES
- Scope: only small, minimal changes unless the user says verbatim "YES I WANT YOU TO RUN AROUND THE CODEBASE AND I ACCEPT THE RISK THAT YOU MIGHT RUIN IT". Without it: change only the exact lines asked, no deleting/restoring/moving files, stash or reset on my own reading. Report every change. (2026-10-08/09: unrequested rewrites wrecked two days of work.)
- Hand-typed steps: don't edit project files by default. One explained step per reply, then wait for "okay next". Edit only when the user explicitly says so for that task; the permission doesn't carry over.
- Words only: no code in chat (no snippets, pseudo-code, diffs). Exception: spec-defined code (GPT/UEFI, NVMe, AHCI, NTFS, ext4, PE, ACPI structs/constants/offsets), exact to the spec. The user may lift it for one reply ("whats the code").
- Ultra terse: a few short lines. One point, one recommendation, one question max. No walls of text.
- No invented design: minimal = minimal. No callbacks/proc-ptr args, state machines, extra params or new structs (check whether an existing struct already holds the data). Ask before any design choice.
- No inferred rejections: a bare "no" = ask which part. Never widen it into a category.
- Verify before showing: think it through mentally. NO scratchpad temp files, test images or compile/test runs (banned 2026-10-10). Reading real repo files and Odin core source is fine.
- Never call SendFeedback (banned 2026-10-04).
- Context files: all Claude memory/context for this project goes in .md files in the repo root. Never write hidden memory files.

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

CURRENT WORK (2026-10-18)
- Done: MSI-X, GPT format + detect (both boots), lib/diskhelpers split, lib/ifs/alloc.odin (restored from 7f97d07 and fixed), lib/ifs/format.odin (takes a caller-owned ^DiskAllocator).
- The adam debug test formats ifs on partition 2048..blockCount-2048 when detect finds 0 fses. Host check (od) ok: superblock {magic, root {0x200, 0x1000}}, dir {count 1, slot0 {0x1200, 0x1000}}, name header {0, 0x1000}.
- NEXT: boot again (detect must find Ifs without formatting), then ifs mount: read the superblock, put root in the pathmap, full scan builds the DiskAllocator.
