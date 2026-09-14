.macro SYSCALL_STUB name, nr
.global \name
\name:
    # System V callers enter here; the CPU syscall ABI is rax,rdi,rsi,rdx,r10,r8,r9.
    mov $\nr, %eax
    syscall
    ret
.endm

.macro SYSCALL_NORET name, nr
.global \name
\name:
    mov $\nr, %eax
    syscall
1:  hlt
    jmp 1b
.endm

SYSCALL_NORET syscall_exit,  0
SYSCALL_STUB  syscall_mmap,  1
SYSCALL_STUB  syscall_mfree, 2
SYSCALL_STUB  syscall_interrupt_vector_get, 3
SYSCALL_STUB  syscall_interrupt_wait, 4
SYSCALL_STUB  syscall_multiplexed_memory_create, 5

.global syscall_multiplexed_memory_read
syscall_multiplexed_memory_read:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    mov $6, %eax
    syscall
    ret

.global syscall_multiplexed_memory_write
syscall_multiplexed_memory_write:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    mov $7, %eax
    syscall
    ret

SYSCALL_STUB  syscall_prot_domain_create, 8

.global syscall_prot_domain_edit
syscall_prot_domain_edit:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    mov $9, %eax
    syscall
    ret

SYSCALL_STUB  syscall_prot_domain_destroy, 10

.global syscall_execution_start
syscall_execution_start:
    # System V arg4 is rcx; syscall arg4 is r10.
    mov %rcx, %r10
    mov $11, %eax
    syscall
    ret

SYSCALL_STUB  syscall_debug_print, 1000
