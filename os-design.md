# os design

Core principles live in CLAUDE.md. Device security lives in contracts.md. This file holds system-level design decisions.

Rule: always pick the exokernel design unless it is moronic. The kernel does protection, userland does strategy.

## Allocation of fake phys ranges (disk, VRAM, ports)

- A pool is a protection domain with no threads, holding the free ranges. There is no new kernel object.
- New ProtDomainEdit op `Transfer(from, to, range)`: needs W on `from`'s authority, and `to` = caller or W on `to`'s authority. Moves the range atomically.
- Range not held by `from` -> `.NotOwned` (lost a race, retry). Pinned range -> `.Busy`.
- Alloc = Transfer(pool, me, range). Free = Transfer(me, pool, range).
- The strategy is userland's. Programs sharing a pool keep their own free map (bitmap, buddy, anything) in shared memory with a userland lock. The map is only a hint; the kernel Transfer is the truth.
- Quota = a separate pool domain.
- Why atomic in the kernel: without it two programs racing on one free range both end up with W and corrupt each other's files.

## ifs security

- Adam mounts: at boot it holds the whole partition window, does the full scan, then builds the pool and grants.
- Programs never mount. They get disk perms plus their subtree's root Slot, then use lazy path_lookup.
- Grants are per-file extents for now. Merging adjacent ranges comes later, only if the resource table hurts.
- Crash safe: ranges taken from the pool but never linked into a dir read as free on the next boot scan.
- Dir writes are block read-modify-write. Concurrent writers to one dir need a userland lock in shared memory. Not a kernel matter.
- Who gets which subtree across reboots is policy and lives in adam's config. The kernel and ifs know nothing of it.

## Update requirements

- Zero downtime: no reboot for any update except the kernel. Zero-downtime kernel updates are a later goal.
- Zero friction: an update = write new code to disk + one atomic commit. No manual stopping of programs.
- Crash safe: a crash at any point leaves the old or the new generation, never a mix.
- Rollback: the previous generation stays bootable.
- Running programs are never forced. Each one picks when it moves to new code.

## Why this is cheap here

- Single address space + position independent code: new code loads at a new address, old pointers stay valid, nothing is relocated.
- Libs hold no globals: swapping a lib = calling new code with the same state.
- No daemons: no services to restart.
- The one real cost: a lib defines the layout of state its program owns (e.g. nvme queue structs). A layout change needs migration.

## Code store and generations

- `/code/<hash>`: immutable code blobs (libs, programs, drivers, adam, kernel). Never written in place.
- One manifest = one generation: `name -> <hash>`. Commit is the A/B manifest write (see Storage formats).
- Rollback: the other manifest is the previous generation.
- Garbage: a blob is freed when neither manifest references it. Disk holds at most 2 generations.
- No dependency metadata: a generation is a set built together, so its parts match by construction.
- Windows apps are copied in as is with their own DLLs. Only our winmitator libs update through the manifest.

## Boot

- The ESP holds only the bootloader.
- The bootloader reads raw blocks through UEFI BlockIo and runs our fs libs read-only (pure libs, so the same code runs there). It scans every partition of every format it knows for the system folder.
- Several system folders found: pick the valid manifest with the highest seq.
- Then it loads the kernel + adam + boot lib (nvme, fs) blobs from that manifest.
- The bootloader must stay quick. How it gets updated: not decided, not a priority.
- Everything, the boot set included, is in one atomic generation. There is no second update path.

## Swapping code in a running program

- Libs: the program reloads at a point it picks (e.g. the top of its main loop). No thread is in old code there, so the old code is unmapped right after.
- Layout change: the lib ships a migrate fn (old version state -> new). State structs carry a `version: u32`.
- Stateful owners (adam, device owners): handoff.
  1. Start the new instance.
  2. The old one quiesces and passes a pointer to its state struct (with version).
  3. The new one migrates if needed and takes over the grants.
  4. The old one exits.
- Rule: all of a program's global state is one struct with a version field.

## Contracts swap

- Contracts are data adam installs. Replace one only when its ring has nothing in flight.
- Needs a kernel op: replace contract on an idle ring. Allowed for any caller holding the ring's memory.

## Syscall ABI

- No syscall exists for only one program. Every syscall is for all programs. What a call may touch is decided only by the caller's memory perms, never by who the caller is.
- Programs call the kernel through our syscall lib, never with raw syscall instructions (Windows apps go through winmitator ntdll). The lib ships in the same generation as the kernel.
- Programs never bundle the syscall lib, they load the current generation's.
- The kernel exports `[minAbi, maxAbi]`. Libs assert their ABI is in range. Syscalls are removed after a deprecation window.

## Kernel swap (later goal, not now)

- The kernel state is small and known: pmm, protdomains, grants, rings, pins. Page tables are plain memory and stay in place.
- Steps:
  1. Adam loads the new kernel image at a new address (position independent).
  2. The new kernel migrates the old state into a fresh copy. The old kernel still runs. A failed migrate = drop the copy, nothing changed.
  3. IPI all cores to a quiescent point (every core in userland or idle), interrupts masked.
  4. Switch: load IDT, syscall MSRs, and the state root to the new kernel. Resume cores.
  5. Free the old image and the old state.
- Devices keep running through the swap: rings, pins, and DMA buffers are state, they are carried over.
- Downtime target: one IPI round + table reloads (microseconds).
- Rules from now on:
  - All kernel globals live in one state root struct with a version, layouts `#assert`ed.
  - Kernel state holds no code pointers (contracts are data, keep it that way).
  - No kernel threads, no blocking in kernel mode: every syscall and interrupt runs to completion. So no kernel stack ever holds a return address into old code.
- Between steps 2 and 4 the state must not change: either migrate after quiescing, or re-run migrate on the delta. Decide when implementing.

## Storage formats

- ifs is preferred, not required. Any format works: a fs is just a lib a program loads (ntfs, ext4, fat, ...).
- The system volume can be any format the bootloader has a read-only reader for.
- The generation commit needs no fs feature: two manifest files A and B, each {seq, checksum, name -> hash list}.
  - Update: write the blobs, flush, write the older manifest with seq + 1, flush.
  - Boot: pick the valid-checksum manifest with the highest seq. A torn write fails its checksum, so the other one wins.
  - Works on fat, ntfs, ext4, ifs, raw blocks.

## TODO

- ifs has no security: disk access must go through nvme contracts (contracts.md). Not done.
- ifs parallelism: per-program nvme queues, concurrent writers. Not done.
- Bootloader read-only fs reader.
- Code store + A/B manifest layout.

## Undecided:

- how programs get device access. Options the user named: a spawn args struct with ptrs per device kind (disk, mouse, gpu...), or a userland upcall to adam ("give me the struct to access the disk") where adam decides perms dynamically. User leans to the upcall. Not decided.
