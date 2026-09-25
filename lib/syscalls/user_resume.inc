.equ SA_RAX,512
.equ SA_RBX,520
.equ SA_RCX,528
.equ SA_RDX,536
.equ SA_RSI,544
.equ SA_RDI,552
.equ SA_RBP,560
.equ SA_R8,568
.equ SA_R9,576
.equ SA_R10,584
.equ SA_R11,592
.equ SA_R12,600
.equ SA_R13,608
.equ SA_R14,616
.equ SA_R15,624
.equ SA_RIP,632
.equ SA_RSP,640
.equ SA_RFLAGS,648
.equ SA_GSBASE,656
.equ SA_CONTROL,664
.equ SA_CONTROL_RESTORING,1

.equ SA_FX_RESERVED,464
.equ SA_FX_RESERVED_QWORDS,6
.equ USER_RED_ZONE,128

.equ USER_CS,0x2B
.equ USER_SS,0x23
.equ RESUME_REASON,2

.macro USER_RESUME_BODY
    fxrstor (%rsi)
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
