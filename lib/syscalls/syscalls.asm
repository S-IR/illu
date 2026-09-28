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
SYSCALL_STUB  syscall_prot_domain_create, 1

.global syscall_prot_domain_edit
syscall_prot_domain_edit:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    movabs $(ILLU_SYSCALL_BIT + 2), %rax
    syscall
    ret

SYSCALL_STUB  syscall_prot_domain_destroy, 3


.global syscall_grant_spawn
syscall_grant_spawn:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    movabs $(ILLU_SYSCALL_BIT + 4), %rax
    syscall
    ret

SYSCALL_STUB  syscall_grant_edit, 5

.global cpu_current_index
cpu_current_index:
    rdtscp
    mov %ecx, %eax
    ret

SYSCALL_STUB  syscall_debug_print, 1000

.global user_resume
user_resume:
    USER_RESUME_BODY
