.macro SYSCALL_STUB name, nr
.global \name
\name:
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
