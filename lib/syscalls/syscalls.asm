.equ ILLU_SYSCALL_BIT, 0x8000000000000000
.include "lib/syscalls/user_resume.inc"

.macro SYSCALL_STUB name, nr
.global \name
\name:
    # System V callers enter here; the CPU syscall ABI is rax,rdi,rsi,rdx,r10,r8,r9.
    movabs $(ILLU_SYSCALL_BIT + \nr), %rax
    syscall
    ret
.endm

SYSCALL_STUB  syscall_mmap,  0
SYSCALL_STUB  syscall_mfree, 1
SYSCALL_STUB  syscall_multiplexed_memory_create, 2

.global syscall_multiplexed_memory_read
syscall_multiplexed_memory_read:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    movabs $(ILLU_SYSCALL_BIT + 3), %rax
    syscall
    ret

.global syscall_multiplexed_memory_write
syscall_multiplexed_memory_write:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    movabs $(ILLU_SYSCALL_BIT + 4), %rax
    syscall
    ret

SYSCALL_STUB  syscall_prot_domain_create, 5

.global syscall_prot_domain_edit
syscall_prot_domain_edit:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    movabs $(ILLU_SYSCALL_BIT + 6), %rax
    syscall
    ret

SYSCALL_STUB  syscall_prot_domain_destroy, 7

.global syscall_grant_spawn
syscall_grant_spawn:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    movabs $(ILLU_SYSCALL_BIT + 8), %rax
    syscall
    ret

SYSCALL_STUB  syscall_grant_edit, 9

.global cpu_current_index
cpu_current_index:
    rdtscp
    mov %ecx, %eax
    ret

SYSCALL_STUB  syscall_debug_print, 1000

.global user_resume
user_resume:
    USER_RESUME_BODY
