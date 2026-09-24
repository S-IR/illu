this is an exokernel that is meant to be as simple as possible, run as fast as possible, run windows apps natively (literally copy and paste the executables and their files in). it is a libos design where we put as much stuff in userland libraries that each "process" runs.
kernel gives the tool blocks to manage memory between programs (sharing , multiplexing etc.) any other abstractions are built ontop on memory and permissions to it
single address space as default. speecial programs can access and do logical addresses.
every program / lib is code. position independent, dumb. no distinction between static and dynamic libraries. . executables are just libraries that you specify an enter fn.
we avoid daemons and we instead go for many decentralized apps that do not trust each other having memory contracts around devices ("we share this block of memory, i can lock this memory for x ms to do my business then i let you" bla bla). each program loads a userlib to work with the hardware as close as possible while respecting the contract.
DO NOT WRITE ANY CODE IN ANY FILES YOURSELF UNLESS I LITERALLY ASK YOU TO MODIFY FILES. PRINT HERE IN THIS CHAT STEP BY STEP CHANGES OF THE CODEBASE + CODE
BE WAY WAY WAY LESS VERBOSE

Exokernel / XN (MIT, Kaashoek & Engler) — the direct ancestor of your design. Kernel does only protection (fine-grained disk/memory access rights); each app links a library FS that manages layout/naming itself. Multiple untrusted libFSes safely multiplex the same disk. This is your model already — just needs a memory analog instead of disk.
Application Performance and Flexibility on Exokernel Systems (https://web.stanford.edu/class/cs240/readings/exokernel.pdf) · Exokernel arch (https://scispace.com/pdf/the-exokernel-operating-system-architecture-16q1utxep5.pdf)

Mungi (UNSW) — single-address-space OS, no FS abstraction at all: everything is a persistent object named/protected by sparse capabilities ("passports"). Directly relevant since you're already single-address-space — suggests treating "files" as capability-named persistent memory regions, not a separate subsystem.
Mungi SASOS (https://cgi.cse.unsw.edu.au/~reports/papers/9705.pdf)

Exokernel / XN (MIT, Kaashoek & Engler) — the direct ancestor of your design. Kernel does only protection (fine-grained disk/memory access rights); each app links a library FS that manages layout/naming itself. Multiple untrusted libFSes safely multiplex the same disk. This is your model already — just needs a memory analog instead of disk.
Application Performance and Flexibility on Exokernel Systems (https://web.stanford.edu/class/cs240/readings/exokernel.pdf) · Exokernel arch (https://scispace.com/pdf/the-exokernel-operating-system-architecture-16q1utxep5.pdf)

Mungi (UNSW) — single-address-space OS, no FS abstraction at all: everything is a persistent object named/protected by sparse capabilities ("passports"). Directly relevant since you're already single-address-space — suggests treating "files" as capability-named persistent memory regions, not a separate subsystem.
Mungi SASOS (https://cgi.cse.unsw.edu.au/~reports/papers/9705.pdf)

Nemesis (Cambridge) — vertically-structured, no daemons/servers, self-paging, QoS isolation pushed to apps. Validates your "no daemons" stance as a known working design point.
Self-Paging in Nemesis (https://www.usenix.org/legacy/event/osdi99/full_papers/hand/hand.pdf)

NOVA (UCSD) — per-inode append-only logs, lock-free, one open txn per core. Disjoint objects never touch the same cache line/lock. This is the pattern for letting mutually-distrusting processes mutate different files with zero coordination.
NOVA (FAST'16) (https://cseweb.ucsd.edu/~swanson/papers/FAST2016NOVA.pdf)

ScaleFS (MIT PDOS) — decouples in-memory FS (fully concurrent/commutative structures, per-core op-log) from on-disk representation; disk sync is a lazy background fold. Scales linearly to 80 cores.
ScaleFS (SOSP'17) (https://pdos.csail.mit.edu/papers/scalefs.pdf)

Strata (UT Austin/KAIST) — private per-application user-space log (fast path, no sharing) + async, separate consolidation into the shared/global structure. Maps almost exactly onto your "memory contract" idea (I own this log, I merge on my terms).
Strata (SOSP'17) (https://www.cs.utexas.edu/~witchel/pubs/kwon17sosp-strata.pdf)
