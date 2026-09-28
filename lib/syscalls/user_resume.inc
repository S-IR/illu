.equ SA_RAX,0
.equ SA_RBX,8
.equ SA_RCX,16
.equ SA_RDX,24
.equ SA_RSI,32
.equ SA_RDI,40
.equ SA_RBP,48
.equ SA_R8,56
.equ SA_R9,64
.equ SA_R10,72
.equ SA_R11,80
.equ SA_R12,88
.equ SA_R13,96
.equ SA_R14,104
.equ SA_R15,112
.equ SA_RIP,120
.equ SA_RSP,128
.equ SA_RFLAGS,136
.equ SA_GSBASE,144
.equ SA_CONTROL,152
.equ SA_XSAVE_MASK,160
.equ SA_XSAVE,192
.equ SA_CONTROL_RESTORING,1
.equ SA_GPR_QWORDS,15

.equ USER_RED_ZONE,128

.equ USER_CS,0x2B
.equ USER_SS,0x23
.equ RESUME_REASON,2

.macro USER_RESUME_BODY
    mov SA_XSAVE_MASK(%rsi), %eax
    mov SA_XSAVE_MASK+4(%rsi), %edx
    xrstor SA_XSAVE(%rsi)
    mov SA_GSBASE(%rsi), %rax
    wrgsbase %rax
    mov SA_RSP(%rsi), %rsp
    sub $USER_RED_ZONE, %rsp
    pushq SA_RIP(%rsi)
    pushq SA_RFLAGS(%rsi)
    pushq SA_RSI(%rsi)
    mov SA_RAX(%rsi), %rax
    mov SA_RBX(%rsi), %rbx
    mov SA_RCX(%rsi), %rcx
    mov SA_RDX(%rsi), %rdx
    mov SA_RDI(%rsi), %rdi
    mov SA_RBP(%rsi), %rbp
    mov SA_R8(%rsi), %r8
    mov SA_R9(%rsi), %r9
    mov SA_R10(%rsi), %r10
    mov SA_R11(%rsi), %r11
    mov SA_R12(%rsi), %r12
    mov SA_R13(%rsi), %r13
    mov SA_R14(%rsi), %r14
    mov SA_R15(%rsi), %r15
    andq $~SA_CONTROL_RESTORING, SA_CONTROL(%rsi)
    pop %rsi
    popfq
    ret $USER_RED_ZONE
.endm
