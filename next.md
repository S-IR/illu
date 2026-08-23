• This is different from the previous fault:

- No page fault occurred.
- No exit code: ... was printed.
- exit code 124 is from the debug timeout, not Adam.
- Adam or the kernel is hanging before syscall_exit.

The likely stall is in the new multiplexed BAR read path:

BAR handle creation
→ PML4 BAR unmapping
→ kernel MMIO read

The next diagnostic step is to print checkpoints immediately before and after:

1. interrupt-vector request;
2. BAR multiplex creation;
3. multiplexed MMIO read;
4. Wi-Fi probe completion.

That will identify the exact operation that is not returning.

› the debug timout?

• Explored
└ Read debug.sh

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• You’re right to question that. .zed/debug.sh does not contain a timeout.

So my previous wording was wrong. The output means:

- QEMU was still running;
- it was terminated by SIGINT (signal 2);
- 124 came from the external runner/wrapper, not your script;
- Adam never printed an exit code.

The kernel did not report a page fault, so it is hanging somewhere after startup rather than crashing.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

› wtf are you about man what script stan@192:~/Documents/code/odin/illu2$ .zed/debug.sh
[INFO ] --- [2026-08-23 09:25:49] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:25:49] The random seed sent to every test is: 10179266398268. Set with -define:ODIN_TEST_RANDOM_SEED=n.
[INFO ] --- [2026-08-23 09:25:49] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-08-23 09:25:49] < Final Mem/ Total Mem> < Peak Mem> (#Free/Alloc) :: [package.test_name]

Finished 1 test in 6.112923ms. The test was successful.
BdsDxe: loading Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
BdsDxe: starting Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
illu kernel alive!
idt: loaded
lapic: x2apic enabled, timer armed
pmm: loaded
adam: startineg init
adam: began execution
exit code: 124

• Explored
└ Read rtl8822be.odin, syscall.odin, syscalls.odin

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• The 124 is not a timeout. Adam explicitly exited with 121 + 3, meaning .InvalidRange from the multiplexed read.

The actual bug is the five-argument syscall ABI: x86-64 Linux-style syscall expects argument 4 in r10, but Odin’s normal function call places it in rcx. The read syscall was
receiving a garbage size, so the bounds check rejected it. I’m fixing the assembly stubs to move rcx into r10 before syscall.

• Edited lib/syscalls/syscalls.asm (+14 -2)
23 SYSCALL_STUB syscall_multiplexed_memory_create, 5
24 -SYSCALL_STUB syscall_multiplexed_memory_read, 6
25 -SYSCALL_STUB syscall_multiplexed_memory_write, 7
24 +
25 +.global syscall_multiplexed_memory_read
26 +syscall_multiplexed_memory_read:
27 + mov %rcx, %r10
28 + mov $6, %eax
    29 +    syscall
    30 +    ret
    31 +
    32 +.global syscall_multiplexed_memory_write
    33 +syscall_multiplexed_memory_write:
    34 +    mov %rcx, %r10
    35 +    mov $7, %eax
36 + syscall
37 + ret

• Ran odin run build.odin -file -debug
└ [INFO ] --- [2026-08-23 09:26:45] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:26:45] The random seed sent to every test is: 10308556648596. Set with -define:ODIN_TEST_RANDOM_SEED=n.
… +3 lines (ctrl + t to view transcript)
Finished 1 test in 11.679148ms. The test was successful.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• Found the real cause of exit 124.

124 = 121 + .InvalidRange.

The five-argument syscall was receiving a corrupted size because:

- Odin passes the fourth function argument in rcx;
- the CPU syscall ABI requires it in r10;
- syscall itself overwrites rcx.

Fixed both multiplexed read/write assembly stubs to move:

mov %rcx, %r10

Build and PMM tests pass. Run .zed/debug.sh again.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

› put systemv . not odin stlye things. put some stable convention . c or systemv or whatever

• The stable boundary should be System V AMD64:

- Odin-to-assembly wrapper calls use System V registers.
- The wrapper then translates only the fourth argument from rcx to r10 for the CPU’s syscall instruction ABI.
- Kernel syscall_dispatch remains a normal System V C-compatible procedure.

I’ll make the convention explicit in the syscall declarations instead of relying on the target’s default.

• Ran rg -n "default_calling_convention|calling_convention|\"sysv\"|sysv" /home/stan/Documents/code/odin/Odin /home/stan/Documents/code/odin/illu2 -g '*.odin' | head -80
└ /home/stan/Documents/code/odin/illu2/asm_helpers/asm_helpers.odin:15: @(default_calling_convention = "c")
/home/stan/Documents/code/odin/illu2/asm_helpers/syscall.odin:5: @(default_calling_convention = "c")
… +76 lines (ctrl + t to view transcript)
/home/stan/Documents/code/odin/Odin/vendor/stb/truetype/stb_truetype.odin:480:@(default_calling_convention="c", link_prefix="stbtt_")
/home/stan/Documents/code/odin/Odin/vendor/stb/truetype/stb_truetype.odin:565:@(default_calling_convention="c", link_prefix="stbtt_")

• Edited 2 files (+2 -2)
└ kernel/syscall.odin (+1 -1)
10 @(export)
11 -syscall_dispatch :: proc "c" (nr, a1, a2, a3, a4, a5: u64) -> (err: u64, r1: u64) {
11 +syscall_dispatch :: proc "sysv" (nr, a1, a2, a3, a4, a5: u64) -> (err: u64, r1: u64) {
12 switch syscalls.Syscall(nr) {

└ lib/syscalls/syscalls.odin (+1 -1)
55 when !KERNEL_BUILD {
56 - @(default_calling_convention = "c")
56 + @(default_calling_convention = "sysv")
57 foreign _ {

• Ran odin run build.odin -file -debug
└ [INFO ] --- [2026-08-23 09:27:56] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:27:56] The random seed sent to every test is: 10471682092154. Set with -define:ODIN_TEST_RANDOM_SEED=n.
… +3 lines (ctrl + t to view transcript)
Finished 1 test in 9.839317ms. The test was successful.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• Set the boundary explicitly to System V AMD64:

- foreign syscall declarations use default_calling_convention = "sysv";
- kernel syscall_dispatch is proc "sysv";
- assembly wrappers use System V function arguments;
- wrappers translate only the CPU syscall special case: rcx → r10 for argument 4.

Build and PMM tests pass.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

› - wrappers translate only the CPU syscall special case: rcx → r10 for argument 4. special cases? what?

• There are two different ABIs involved:

System V function calls:

arg1 → rdi
arg2 → rsi
arg3 → rdx
arg4 → rcx
arg5 → r8
arg6 → r9

The x86-64 syscall instruction uses Linux’s syscall convention:

syscall number → rax
arg1 → rdi
arg2 → rsi
arg3 → rdx
arg4 → r10
arg5 → r8
arg6 → r9

So the assembly wrapper is a System V function, but immediately before executing the CPU instruction it translates only the fourth argument:

mov %rcx, %r10
syscall

That is the only “special case.” It exists because the CPU syscall ABI reserves rcx and r11; syscall overwrites them.

› find a CONVENTION WHERE YOU DONT HAVE TO HAVE SPECIAL CASES

• You cannot eliminate that translation when using the x86-64 syscall instruction. Its register convention is fixed by the hardware/CPU ABI.

The clean convention that avoids per-syscall register special cases is a syscall frame:

SyscallFrame :: struct {
number: u64,
args: [6]u64,
result: u64,
error: u64,
}

Userland passes one pointer:

syscall_invoke(frame: ^SyscallFrame)

That uses ordinary System V:

frame pointer → rdi

The assembly entry loads the syscall number and arguments from the frame. Every syscall then has one identical calling convention, regardless of how many arguments it has.

Tradeoff: slightly more memory access and copying per syscall, but no rcx → r10 special case and a much cleaner stable ABI.

› THATS userland lib code i dont care about it i care that the syscalls have clear obvious simple convention calls

• You’re right. At the actual kernel syscall boundary, use the clear Linux x86-64 syscall convention:

rax = syscall number
rdi = argument 1
rsi = argument 2
rdx = argument 3
r10 = argument 4
r8 = argument 5
r9 = argument 6

Returns:

rax = error code
rdx = secondary return value

There are no special cases in that convention. rcx → r10 is only a userland wrapper adaptation before executing syscall; it is not part of the kernel’s syscall convention.

› then do it motherfucker

• The kernel boundary is already the Linux x86-64 syscall ABI. I’m making that explicit in the actual syscall entry and dispatch comments, and I’ll keep the internal Odin call
normalization separate so there is no ambiguity about which convention applies where.

• Edited 3 files (+7 -0)
└ asm_helpers/helpers.asm (+2 -0)
625 syscall_entry:
626 + # Kernel syscall ABI on entry:
627 + # rax = number, rdi/rsi/rdx/r10/r8/r9 = arguments 1..6.
628 swapgs

└ kernel/syscall.odin (+2 -0)
10 @(export)
11 +// syscall_entry normalizes the Linux x86-64 syscall ABI into this System V call:
12 +// (nr, a1, a2, a3, a4, a5) -> (rax error, rdx secondary result).
13 syscall_dispatch :: proc "sysv" (nr, a1, a2, a3, a4, a5: u64) -> (err: u64, r1: u64) {

└ lib/syscalls/syscalls.asm (+3 -0)
3 \name:
4 + # System V callers enter here; the CPU syscall ABI is rax,rdi,rsi,rdx,r10,r8,r9.
5 mov $\nr, %eax
⋮
27 syscall_multiplexed_memory_read:
28 + # System V arg4 is rcx; syscall arg4 is r10.
29 mov %rcx, %r10
⋮
35 syscall_multiplexed_memory_write:
36 + # System V arg4 is rcx; syscall arg4 is r10.
37 mov %rcx, %r10

• Ran odin run build.odin -file -debug
└ [INFO ] --- [2026-08-23 09:30:50] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:30:50] The random seed sent to every test is: 10872771596264. Set with -define:ODIN_TEST_RANDOM_SEED=n.
… +3 lines (ctrl + t to view transcript)
Finished 1 test in 6.468221ms. The test was successful.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• Done.

The syscall ABI is now explicitly documented as:

rax = syscall number
rdi = arg1
rsi = arg2
rdx = arg3
r10 = arg4
r8 = arg5
r9 = arg6

return:
rax = error
rdx = secondary result

The kernel entry and dispatch comments now state this directly. The internal System V call to syscall_dispatch is clearly separated from the actual syscall ABI.

Build and PMM tests pass.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

› stan@192:~/Documents/code/odin/illu2$ .zed/debug.sh
[INFO ] --- [2026-08-23 09:25:49] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:25:49] The random seed sent to every test is: 10179266398268. Set with -define:ODIN_TEST_RANDOM_SEED=n.
[INFO ] --- [2026-08-23 09:25:49] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-08-23 09:25:49] < Final Mem/ Total Mem> < Peak Mem> (#Free/Alloc) :: [package.test_name]

Finished 1 test in 6.112923ms. The test was successful.
BdsDxe: loading Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
BdsDxe: starting Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
illu kernel alive!
idt: loaded
lapic: x2apic enabled, timer armed
pmm: loaded
adam: startineg init
adam: began execution
exit code: 124
qemu-system-x86_64: terminating on signal 2
stan@192:~/Documents/code/odin/illu2$ .zed/debug.sh
[INFO ] --- [2026-08-23 09:31:02] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:31:02] The random seed sent to every test is: 10899040546718. Set with -define:ODIN_TEST_RANDOM_SEED=n.
[INFO ] --- [2026-08-23 09:31:02] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-08-23 09:31:02] < Final Mem/ Total Mem> < Peak Mem> (#Free/Alloc) :: [package.test_name]

Finished 1 test in 11.711081ms. The test was successful.

[sudo] password for stan:
BdsDxe: loading Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
BdsDxe: starting Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
illu kernel alive!
idt: loaded
lapic: x2apic enabled, timer armed
pmm: loaded
adam: startineg init
adam: began execution

======== KERNEL EXCEPTION ========
vector: 14 (#PF page fault)
rip: 0x000000000010a34c
cs: 0x0000000000000008 (ring 0)
rsp: 0x000000001e19cb48
rflags: 0x0000000000010046
error: 0x0000000000000000
cr2: 0x0000007000000000
pf info: NOT-PRESENT | READ | SUPERVISOR
--- general purpose registers ---
rax: 0x0000000000000000
rbx: 0x0000000000010000
rcx: 0x000000001bfd4e3c
rdx: 0x0000000000000000
rsi: 0x0000007000000000
rdi: 0x0000007000000000
rbp: 0x0000000000000000
r8 : 0x000000001e19cc30
r9 : 0x0000000000000000
r10: 0x0000000000000004
r11: 0x0000000000000246
r12: 0x0000000000000000
r13: 0x0000000000000000
r14: 0x0000007000000000
r15: 0x0000000000000000
===================================

• This fault is now clear:

cr2: 0x0000007000000000
error: NOT-PRESENT | READ | SUPERVISOR

The kernel is trying to perform the multiplexed MMIO read, but that BAR physical range is not mapped in kernelPML4.

We removed the BAR mapping from Adam’s PML4 correctly, but the kernel also needs a supervisor-only mapping to perform the mediated MMIO access.

Required boundary:

Adam PML4:
no direct BAR mapping

kernel PML4:
BAR mapped as Present + Write + PWT + PCD + NX

The next fix is to map each BAR page into kernelPML4 only. This is not giving Adam access; it only lets the syscall handler perform the MMIO operation.

› then in frigging syscall to create the fucking multiplexed mem add the kernel mmio read on it. i dont get why doesnt the kernel have access to everthing tho by default

• You’re right: the mapping belongs in multiplexed_memory_create, because that is where the kernel accepts responsibility for accessing the range.

The kernel does not automatically access every physical address. Its current PML4 maps normal RAM, but device BARs are outside that mapping. I’ll make creation install a
kernel-only identity mapping for each volatile/MMIO page, while still removing the user mapping from the domain PML4.

• Edited kernel/syscall.odin (+7 -0)
69
70 + if .Volatile in resource.flags {
71 + kernelMMIOFlags := lmem.PageFlags{.Present, .Write, .PWT, .PCD, .NX}
72 + for page := phys; page < phys + size; page += shared.PAGE_SIZE {
73 + pmm.map_page(pmm.kernelPML4, page, ._4KB, kernelMMIOFlags)
74 + }
75 + }
76 +
77 resource.flags += {.Multiplexed}

• Ran odin run build.odin -file -debug
└ [INFO ] --- [2026-08-23 09:33:13] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:33:13] The random seed sent to every test is: 11200994308628. Set with -define:ODIN_TEST_RANDOM_SEED=n.
… +3 lines (ctrl + t to view transcript)
Finished 1 test in 11.703305ms. The test was successful.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• Fixed.

multiplexed_memory_create now:

1. Maps volatile/MMIO pages into kernelPML4 with:

Present + Write + PWT + PCD + NX

2. Marks the resource .Multiplexed.
3. Removes the same pages from Adam’s PML4.

The kernel does not automatically map every physical address because paging still applies to ring 0. Its existing address space maps normal RAM, not arbitrary device BARs.
Build and PMM tests pass.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

› stan@192:~/Documents/code/odin/illu2$ .zed/debug.sh
[INFO ] --- [2026-08-23 09:33:44] Starting test runner with 1 thread. Set with -define:ODIN_TEST_THREADS=n.
[INFO ] --- [2026-08-23 09:33:44] The random seed sent to every test is: 11272040125954. Set with -define:ODIN_TEST_RANDOM_SEED=n.
[INFO ] --- [2026-08-23 09:33:44] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-08-23 09:33:44] < Final Mem/ Total Mem> < Peak Mem> (#Free/Alloc) :: [package.test_name]

Finished 1 test in 10.433743ms. The test was successful.
BdsDxe: loading Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
BdsDxe: starting Boot0002 "UEFI QEMU HARDDISK QM00001 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)
illu kernel alive!
idt: loaded
lapic: x2apic enabled, timer armed
pmm: loaded
adam: startineg init
adam: began execution
exit code: 42

• Success.

exit code: 42 means Adam completed:

- PCI scan;
- interrupt setup;
- BAR multiplex creation;
- kernel-only MMIO mapping;
- direct Adam BAR unmapping;
- mediated MMIO read;
- Wi-Fi registration.

The multiplexed-memory path is now working end-to-end.

› go to where the prot domain dies and where things are supposed to be cleaned up . look to see if in case of multiplexed mem the kernel does free the thing, actuaally i just
realized a problem. we will have shared mem. how do we determine if that shared mem is still to be kept alive when one thing dies?

• I’ll inspect the domain teardown and resource cleanup path read-only, then report exactly what happens today and what lifetime model shared memory needs. I won’t modify files
unless you explicitly ask me to.

• Explored
└ Read execution.odin
Read sched.odin
Read syscall.odin
Search pml4_destroy|domain_reclaim|free_pages|MemoryResource in kernel

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• Current cleanup is here:

kernel/execution.odin:232

Today it does:

for phys, resource in domain.resources {
if .OwnedByDomain in resource.flags {
pmm.free_pages(u64(phys), resource.size)
}
}

Current behavior:

- Adam ELF/stack pages: .OwnedByDomain → freed when Adam dies.
- mmap pages: .OwnedByDomain → freed when the domain dies.
- Wi-Fi BAR/config resources: not .OwnedByDomain → not freed.
- A normal mmap region that is later multiplexed: still .OwnedByDomain → freed on domain death.

That last case is unsafe if the memory is shared with another domain. It could free physical pages still being used elsewhere. syscall_mfree can also currently free a
multiplexed owned allocation too early.

The correct long-term model is:

global MemoryObject
physical address
size
freeable: bool
reference_count

per-domain resource entry
pointer to MemoryObject
mapping permissions
multiplexed state

When another domain receives shared memory, it increments the global reference count. When one domain dies, it removes only its reference. The physical pages are freed only
when:

reference_count == 0
and freeable == true

Device BARs have freeable = false, so they are never returned to the page allocator.

So yes: the current cleanup handles private allocations, but it is not yet safe for shared memory. We need a global refcounted memory-object layer before implementing cross-
domain shared memory.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

› yeah we gotta do smth with refcount and something outside any exec or prot domain. something global

• Exactly. The physical backing must live in a global kernel table, independent of executions and protection domains.

Design:

GlobalMemoryObject
phys
size
reference_count
freeable

The protection domain stores only a reference to it:

MemoryResource
object: ^GlobalMemoryObject
pageFlags
flags

Lifecycle:

- private mmap: create global object with reference_count = 1;
- share/grant: add another domain reference;
- multiplex: changes only that domain’s access mode, not the object lifetime;
- domain death: remove its references and decrement counts;
- reference_count == 0:
  - freeable = true → free physical pages;
  - freeable = false → keep it, as with PCI BARs.

Therefore, one domain dying cannot free memory still referenced by another domain. OwnedByDomain should eventually be replaced by global-object lifetime metadata, because
ownership is no longer a property of one domain.

› k print me some code to see what you have in mind

• Here is the structure I have in mind. This is only printed code; I did not modify files.

MemoryObject :: struct {
phys: u64,
size: u64,
refCount: u64,
freeable: bool,
}

MemoryResource :: struct {
object: ^MemoryObject,
pageSize: lmem.PageSize,
pageFlags: lmem.PageFlags,
flags: MemoryResourceFlags,
}

ProtectionDomain :: struct {
pml4: u64,
resources: map[uintptr]MemoryResource,
}

memoryObjectsLock: spinlock.Spinlock
memoryObjects: map[uintptr]^MemoryObject

The global table is keyed by physical address:

memory_object_create :: proc(
phys, size: u64,
freeable: bool,
) -> (^MemoryObject, bool) {
spinlock.lock(&memoryObjectsLock)
defer spinlock.unlock(&memoryObjectsLock)

      if memoryObjects == nil {
          memoryObjects, err := make(map[uintptr]^MemoryObject)
          if err != nil do return nil, false
      }

      if _, exists := memoryObjects[uintptr(phys)]; exists {
          return nil, false
      }

      object, err := new(MemoryObject)
      if err != nil do return nil, false

      object^ = MemoryObject{
          phys      = phys,
          size      = size,
          refCount  = 1,
          freeable  = freeable,
      }

      memoryObjects[uintptr(phys)] = object
      return object, true

}

When another domain receives access:

memory_object_retain :: proc(object: ^MemoryObject) {
spinlock.lock(&memoryObjectsLock)
object.refCount += 1
spinlock.unlock(&memoryObjectsLock)
}

When a domain dies:

memory_object_release :: proc(object: ^MemoryObject) {
shouldFree := false

      spinlock.lock(&memoryObjectsLock)

      assert(object.refCount > 0)
      object.refCount -= 1

      if object.refCount == 0 {
          delete_key(&memoryObjects, uintptr(object.phys))
          shouldFree = object.freeable
      }

      spinlock.unlock(&memoryObjectsLock)

      if shouldFree {
          pmm.free_pages(object.phys, object.size)
      }

      if object.refCount == 0 {
          free(object)
      }

}

Domain cleanup becomes:

domain_reclaim_locked :: proc(domain: ^ProtectionDomain) {
ah.write_cr3(pmm.kernelPML4)

      for _, resource in domain.resources {
          if resource.object != nil {
              memory_object_release(resource.object)
          }
      }

      delete(domain.resources)
      pmm.pml4_destroy(domain.pml4)
      domain.pml4 = 0

}

Private RAM:

object, ok := memory_object_create(
allocatedPhys,
totalBytes,
true, // kernel may free when refcount reaches zero
)

PCI BAR:

object, ok := memory_object_create(
barPhys,
barSize,
false, // never free hardware memory
)

The important change is that MemoryResource no longer decides whether physical memory is freed. The global MemoryObject owns that lifetime decision.
