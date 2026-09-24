FS REQS

GOALS

- fs behaves like memory. protection like RAM perms, not a separate ACL system.
- many untrusted apps share storage, no daemon mediator.
- minimal kernel involvement per op.
- parallel by default.
- fast header lookup.
- windows-app-compatible enough (mtime etc).

RESEARCH CONSTRAINTS BACKING THE GOALS ABOVE

- metadata ops dominate call volume - 50%+ of fs calls are open/stat/close, not read/write.
- most files are write-once-then-read-many (bimodal). true concurrent read-write on one file
  is rare.
- ~50% of files on a real machine are <2KB (measured on this machine: 166640/342860 files
  under 2048 bytes).
- fragmentation matters a lot for HDD (seek cost), barely matters for SSD/NVMe (no seek
  penalty, controller parallelism doesn't care about extent count) except for header size and
  allocator behavior.
- no meaningful OS-imposed cap on total files/dirs per volume (ext4 ~4B inodes, NTFS ~4.29B
  MFT records) - can't size anything statically assuming a small ceiling.
