.section .data
.global irq_stub_table
irq_stub_table:
    .quad irq32, irq33, irq34, irq35, irq36, irq37, irq38, irq39
    .quad irq40, irq41, irq42, irq43, irq44, irq45, irq46, irq47
    .quad irq48, irq49, irq50, irq51, irq52, irq53, irq54, irq55
    .quad irq56, irq57, irq58, irq59, irq60, irq61, irq62, irq63
    .quad irq64, irq65, irq66, irq67, irq68, irq69, irq70, irq71
    .quad irq72, irq73, irq74, irq75, irq76, irq77, irq78, irq79
    .quad irq80, irq81, irq82, irq83, irq84, irq85, irq86, irq87
    .quad irq88, irq89, irq90, irq91, irq92, irq93, irq94, irq95
    .quad irq96, irq97, irq98, irq99, irq100, irq101, irq102, irq103
    .quad irq104, irq105, irq106, irq107, irq108, irq109, irq110, irq111
    .quad irq112, irq113, irq114, irq115, irq116, irq117, irq118, irq119
    .quad irq120, irq121, irq122, irq123, irq124, irq125, irq126, irq127
    .quad irq128, irq129, irq130, irq131, irq132, irq133, irq134, irq135
    .quad irq136, irq137, irq138, irq139, irq140, irq141, irq142, irq143
    .quad irq144, irq145, irq146, irq147, irq148, irq149, irq150, irq151
    .quad irq152, irq153, irq154, irq155, irq156, irq157, irq158, irq159
    .quad irq160, irq161, irq162, irq163, irq164, irq165, irq166, irq167
    .quad irq168, irq169, irq170, irq171, irq172, irq173, irq174, irq175
    .quad irq176, irq177, irq178, irq179, irq180, irq181, irq182, irq183
    .quad irq184, irq185, irq186, irq187, irq188, irq189, irq190, irq191
    .quad irq192, irq193, irq194, irq195, irq196, irq197, irq198, irq199
    .quad irq200, irq201, irq202, irq203, irq204, irq205, irq206, irq207
    .quad irq208, irq209, irq210, irq211, irq212, irq213, irq214, irq215
    .quad irq216, irq217, irq218, irq219, irq220, irq221, irq222, irq223
    .quad irq224, irq225, irq226, irq227, irq228, irq229, irq230, irq231
    .quad irq232, irq233, irq234, irq235, irq236, irq237, irq238, irq239
.global isr_table
isr_table:
    .quad isr0,  isr1,  isr2,  isr3,  isr4,  isr5,  isr6,  isr7
    .quad isr8,  isr9,  isr10, isr11, isr12, isr13, isr14, isr15
    .quad isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
    .quad isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31

.section .bss
.align 16
.global _kernel_stack
_kernel_stack:
    .skip 16 * 4096
.global _kernel_stack_top
_kernel_stack_top:

.section .text
.org 0
.code16
.global trampoline_start
trampoline_start:
    cli
    cld
    xor %ax, %ax
    mov %ax, %ds
    lgdtl (0x8000 + gdt_desc - trampoline_start)
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0
    ljmpl $0x08, $(0x8000 + protected - trampoline_start)
.code32
protected:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov (0x8000 + patch_cr3 - trampoline_start), %eax
    mov %eax, %cr3
    mov %cr4, %eax
    or $0x620, %eax        // PAE | OSFXSR | OSXMMEXCPT
    mov %eax, %cr4
    mov $0xC0000080, %ecx
    rdmsr
    or $0x900, %eax        // LME | NXE
    wrmsr
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0
ljmpl $0x18, $(0x8000 + long_mode - trampoline_start)
.code64
long_mode:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov (0x8000 + patch_stack - trampoline_start), %rsp
    and $-16, %rsp
    mov (0x8000 + patch_cpu - trampoline_start), %rdi
    mov (0x8000 + patch_entry - trampoline_start), %rax
    call *%rax
1:  hlt
    jmp 1b

.align 8
gdt:
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF
    .quad 0x00CF92000000FFFF
    .quad 0x00AF9A000000FFFF
    .quad 0x00AF92000000FFFF
gdt_desc:
    .word gdt_desc - gdt - 1
    .long 0x8000 + gdt - trampoline_start
.global patch_cr3
patch_cr3:   .quad 0
.global patch_stack
patch_stack: .quad 0
.global patch_entry
patch_entry: .quad 0
.global patch_cpu
patch_cpu: .quad 0
.global trampoline_end
trampoline_end:
    nop

.global kernel_start_setup
kernel_start_setup:
    cli
    cld
    lea _kernel_stack_top(%rip), %rsp
    and $-16, %rsp
    call kernel_main
.halt_loop:
    hlt
    jmp .halt_loop

.global serial_init_asm
serial_init_asm:
    mov $0x3F9, %dx
    mov $0x00, %al
    out %al, %dx
    mov $0x3FB, %dx
    mov $0x80, %al
    out %al, %dx
    mov $0x3F8, %dx
    mov $0x03, %al
    out %al, %dx
    mov $0x3F9, %dx
    mov $0x00, %al
    out %al, %dx
    mov $0x3FB, %dx
    mov $0x03, %al
    out %al, %dx
    mov $0x3FA, %dx
    mov $0xC7, %al
    out %al, %dx
    ret

.global serial_write_byte_asm
serial_write_byte_asm:
    push %rdi
1:
    mov $0x3FD, %dx
    in %dx, %al
    test $0x20, %al
    jz 1b
    pop %rdi
    mov $0x3F8, %dx
    mov %dil, %al
    out %al, %dx
    ret

.global int3me
int3me:
    int3

.global lgdt_asm
lgdt_asm:
    lgdt (%rdi)
    ret

.global reload_segments_asm
reload_segments_asm:
    pushq  $0x08
    leaq   1f(%rip), %rax
    pushq  %rax
    lretq
1:
    movw   $0x10, %ax
    movw   %ax, %ds
    movw   %ax, %es
    movw   %ax, %ss
    xorw   %ax, %ax
    movw   %ax, %fs
    ret

.macro IRQ_STUB num
.global irq\num
irq\num:
    push $0
    push $\num
    jmp interrupt_dispatch
.endm

.macro ISR_NOERR num
.global isr\num
isr\num:
    push $0
    push $\num
    jmp interrupt_dispatch
.endm

.macro ISR_ERR num
.global isr\num
isr\num:
    push $\num
    jmp interrupt_dispatch
.endm

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_ERR   30
ISR_NOERR 31

IRQ_STUB 32
IRQ_STUB 33
IRQ_STUB 34
IRQ_STUB 35
IRQ_STUB 36
IRQ_STUB 37
IRQ_STUB 38
IRQ_STUB 39
IRQ_STUB 40
IRQ_STUB 41
IRQ_STUB 42
IRQ_STUB 43
IRQ_STUB 44
IRQ_STUB 45
IRQ_STUB 46
IRQ_STUB 47
IRQ_STUB 48
IRQ_STUB 49
IRQ_STUB 50
IRQ_STUB 51
IRQ_STUB 52
IRQ_STUB 53
IRQ_STUB 54
IRQ_STUB 55
IRQ_STUB 56
IRQ_STUB 57
IRQ_STUB 58
IRQ_STUB 59
IRQ_STUB 60
IRQ_STUB 61
IRQ_STUB 62
IRQ_STUB 63

interrupt_dispatch:
    push %r15
    push %r14
    push %r13
    push %r12
    push %r11
    push %r10
    push %r9
    push %r8
    push %rbp
    push %rdi
    push %rsi
    push %rdx
    push %rcx
    push %rbx
    push %rax

    testb $3, 144(%rsp)
    jz 1f
    swapgs
1:
    mov %rsp, %rdi
    call exception_handler

    testb $3, 144(%rsp)
    jz 2f
    swapgs
2:
    pop %rax
    pop %rbx
    pop %rcx
    pop %rdx
    pop %rsi
    pop %rdi
    pop %rbp
    pop %r8
    pop %r9
    pop %r10
    pop %r11
    pop %r12
    pop %r13
    pop %r14
    pop %r15

    add $16, %rsp
    iretq

.global halt
halt:
    hlt
    jmp halt

.global load_tss_asm
load_tss_asm:
    ltrw   %di
    ret

.global lidt_asm
lidt_asm:
    lidt (%rdi)
    ret

.global read_cr2
read_cr2:
    mov %cr2, %rax
    ret

.global read_cr3
read_cr3:
    mov %cr3, %rax
    ret

.global write_cr3
write_cr3:
    mov %rdi, %cr3
    ret

.global wrmsr_asm
wrmsr_asm:
    movl   %edi, %ecx
    movl   %esi, %eax
    movq   %rsi, %rdx
    shrq   $32, %rdx
    wrmsr
    ret

.global rdmsr_asm
rdmsr_asm:
    movl   %edi, %ecx
    rdmsr
    shlq   $32, %rdx
    orq    %rdx, %rax
    ret

.global cpuid_asm
cpuid_asm:
    push   %rbx
    push   %rdx
    movl   %edi, %eax
    movl   %esi, %ecx
    cpuid
    pop    %rdi
    movl   %eax, (%rdi)
    movl   %ebx, 4(%rdi)
    movl   %ecx, 8(%rdi)
    movl   %edx, 12(%rdi)
    pop    %rbx
    ret

.section .data
.global apic_stub_table
apic_stub_table:
    .quad irq240, irq241, irq242, irq243, irq244, irq245

.section .text
IRQ_STUB 64
IRQ_STUB 65
IRQ_STUB 66
IRQ_STUB 67
IRQ_STUB 68
IRQ_STUB 69
IRQ_STUB 70
IRQ_STUB 71
IRQ_STUB 72
IRQ_STUB 73
IRQ_STUB 74
IRQ_STUB 75
IRQ_STUB 76
IRQ_STUB 77
IRQ_STUB 78
IRQ_STUB 79
IRQ_STUB 80
IRQ_STUB 81
IRQ_STUB 82
IRQ_STUB 83
IRQ_STUB 84
IRQ_STUB 85
IRQ_STUB 86
IRQ_STUB 87
IRQ_STUB 88
IRQ_STUB 89
IRQ_STUB 90
IRQ_STUB 91
IRQ_STUB 92
IRQ_STUB 93
IRQ_STUB 94
IRQ_STUB 95
IRQ_STUB 96
IRQ_STUB 97
IRQ_STUB 98
IRQ_STUB 99
IRQ_STUB 100
IRQ_STUB 101
IRQ_STUB 102
IRQ_STUB 103
IRQ_STUB 104
IRQ_STUB 105
IRQ_STUB 106
IRQ_STUB 107
IRQ_STUB 108
IRQ_STUB 109
IRQ_STUB 110
IRQ_STUB 111
IRQ_STUB 112
IRQ_STUB 113
IRQ_STUB 114
IRQ_STUB 115
IRQ_STUB 116
IRQ_STUB 117
IRQ_STUB 118
IRQ_STUB 119
IRQ_STUB 120
IRQ_STUB 121
IRQ_STUB 122
IRQ_STUB 123
IRQ_STUB 124
IRQ_STUB 125
IRQ_STUB 126
IRQ_STUB 127
IRQ_STUB 128
IRQ_STUB 129
IRQ_STUB 130
IRQ_STUB 131
IRQ_STUB 132
IRQ_STUB 133
IRQ_STUB 134
IRQ_STUB 135
IRQ_STUB 136
IRQ_STUB 137
IRQ_STUB 138
IRQ_STUB 139
IRQ_STUB 140
IRQ_STUB 141
IRQ_STUB 142
IRQ_STUB 143
IRQ_STUB 144
IRQ_STUB 145
IRQ_STUB 146
IRQ_STUB 147
IRQ_STUB 148
IRQ_STUB 149
IRQ_STUB 150
IRQ_STUB 151
IRQ_STUB 152
IRQ_STUB 153
IRQ_STUB 154
IRQ_STUB 155
IRQ_STUB 156
IRQ_STUB 157
IRQ_STUB 158
IRQ_STUB 159
IRQ_STUB 160
IRQ_STUB 161
IRQ_STUB 162
IRQ_STUB 163
IRQ_STUB 164
IRQ_STUB 165
IRQ_STUB 166
IRQ_STUB 167
IRQ_STUB 168
IRQ_STUB 169
IRQ_STUB 170
IRQ_STUB 171
IRQ_STUB 172
IRQ_STUB 173
IRQ_STUB 174
IRQ_STUB 175
IRQ_STUB 176
IRQ_STUB 177
IRQ_STUB 178
IRQ_STUB 179
IRQ_STUB 180
IRQ_STUB 181
IRQ_STUB 182
IRQ_STUB 183
IRQ_STUB 184
IRQ_STUB 185
IRQ_STUB 186
IRQ_STUB 187
IRQ_STUB 188
IRQ_STUB 189
IRQ_STUB 190
IRQ_STUB 191
IRQ_STUB 192
IRQ_STUB 193
IRQ_STUB 194
IRQ_STUB 195
IRQ_STUB 196
IRQ_STUB 197
IRQ_STUB 198
IRQ_STUB 199
IRQ_STUB 200
IRQ_STUB 201
IRQ_STUB 202
IRQ_STUB 203
IRQ_STUB 204
IRQ_STUB 205
IRQ_STUB 206
IRQ_STUB 207
IRQ_STUB 208
IRQ_STUB 209
IRQ_STUB 210
IRQ_STUB 211
IRQ_STUB 212
IRQ_STUB 213
IRQ_STUB 214
IRQ_STUB 215
IRQ_STUB 216
IRQ_STUB 217
IRQ_STUB 218
IRQ_STUB 219
IRQ_STUB 220
IRQ_STUB 221
IRQ_STUB 222
IRQ_STUB 223
IRQ_STUB 224
IRQ_STUB 225
IRQ_STUB 226
IRQ_STUB 227
IRQ_STUB 228
IRQ_STUB 229
IRQ_STUB 230
IRQ_STUB 231
IRQ_STUB 232
IRQ_STUB 233
IRQ_STUB 234
IRQ_STUB 235
IRQ_STUB 236
IRQ_STUB 237
IRQ_STUB 238
IRQ_STUB 239
IRQ_STUB 240
IRQ_STUB 241
IRQ_STUB 242
IRQ_STUB 243
IRQ_STUB 244
IRQ_STUB 245

.global rdtsc_asm
rdtsc_asm:
    rdtsc
    shlq $32, %rdx
    orq  %rdx, %rax
    ret

.global inb
inb:
    movw   %di, %dx
    xorl   %eax, %eax
    inb    %dx, %al
    ret

.global outb
outb:
    movw   %di, %dx
    movb   %sil, %al
    outb   %al, %dx
    ret

.global sti_asm
sti_asm:
    sti
    ret



.global read_rsp
read_rsp:
    mov %rsp, %rax
    ret

.global read_rbp
read_rbp:
    mov %rbp, %rax
    ret

.global gs_write_base
gs_write_base:
    movl $0xC0000101, %ecx
    movl %edi, %eax
    shrq $32, %rdi
    movl %edi, %edx
    wrmsr
    ret

.global gs_read_cpustate
gs_read_cpustate:
    movq %gs:0, %rax
    ret

.global syscall_entry
syscall_entry:
    swapgs
    mov %rsp, %gs:16
    mov %gs:8, %rsp

    push %rax
    mov %cr3, %rax
    push %rax
    mov kernelPML4(%rip), %rax
    mov %rax, %cr3

    push %rcx
    push %r11
    sub $688, %rsp
    mov %rsp, %gs:40

    mov 712(%rsp), %rax
    mov %rax, SS_RAX(%rsp)
    mov %rbx, SS_RBX(%rsp)
    mov 696(%rsp), %rax
    mov %rax, SS_RCX(%rsp)
    mov %rdx, SS_RDX(%rsp)
    mov %rsi, SS_RSI(%rsp)
    mov %rdi, SS_RDI(%rsp)
    mov %rbp, SS_RBP(%rsp)
    mov %r8, SS_R8(%rsp)
    mov %r9, SS_R9(%rsp)
    mov %r10, SS_R10(%rsp)
    mov 688(%rsp), %rax
    mov %rax, SS_R11(%rsp)
    mov %r12, SS_R12(%rsp)
    mov %r13, SS_R13(%rsp)
    mov %r14, SS_R14(%rsp)
    mov %r15, SS_R15(%rsp)
    mov 696(%rsp), %rax
    mov %rax, SS_RIP(%rsp)
    mov $0x2B, %rax
    mov %rax, SS_CS(%rsp)
    mov 688(%rsp), %rax
    mov %rax, SS_RFLAGS(%rsp)
    mov %gs:16, %rax
    mov %rax, SS_RSP(%rsp)
    mov $0x23, %rax
    mov %rax, SS_SS(%rsp)
    mov $1, %rax
    mov %rax, 672(%rsp)

    mov %r8,  %r9
    mov %r10, %r8
    mov %rdx, %rcx
    mov %rsi, %rdx
    mov %rdi, %rsi
    mov 712(%rsp), %rdi
    call syscall_dispatch

    movq $0, %gs:40
    add $688, %rsp
    pop %r11
    pop %rcx
    pop %r10
    mov %r10, %cr3
    add $8, %rsp
    mov %gs:16, %rsp
    swapgs
    sysretq


.global cpu_idle_loop
cpu_idle_loop:
    sti
    call run_next_execution
    cli
    test %al, %al
    jnz cpu_idle_loop           
    call cpu_prepare_sleep      
    test %al, %al
    jz cpu_idle_loop             
    sti
    mov kernel_mwait_hint(%rip), %eax
    xor %ecx, %ecx
    mwait
    call cpu_clear_sleeping
    jmp cpu_idle_loop


.equ SS_RAX,0
.equ SS_RBX,8
.equ SS_RCX,16
.equ SS_RDX,24
.equ SS_RSI,32
.equ SS_RDI,40
.equ SS_RBP,48
.equ SS_R8,56
.equ SS_R9,64
.equ SS_R10,72
.equ SS_R11,80
.equ SS_R12,88
.equ SS_R13,96
.equ SS_R14,104
.equ SS_R15,112
.equ SS_RIP,120
.equ SS_CS,128
.equ SS_RFLAGS,136
.equ SS_RSP,144
.equ SS_SS,152
.equ SS_FXSAVE,160

.equ CPU_SCHEDRESUME,32

.global fxsave_asm
fxsave_asm:
    fxsave (%rdi)
    ret

.global mmio_read_u8
mmio_read_u8:
    movzbl (%rdi), %eax
    ret

.global mmio_read_u16
mmio_read_u16:
    movzwl (%rdi), %eax
    ret

.global mmio_read_u32
mmio_read_u32:
    movl (%rdi), %eax
    ret

.global mmio_write_u8
mmio_write_u8:
    movb %sil, (%rdi)
    ret

.global mmio_write_u16
mmio_write_u16:
    movw %si, (%rdi)
    ret

.global mmio_write_u32
mmio_write_u32:
    movl %esi, (%rdi)
    ret

.global monitor_asm
monitor_asm:
    mov %rdi, %rax
    xor %ecx, %ecx
    xor %edx, %edx
    monitor
    ret

.global lock_asm
.type lock_asm, @function
lock_asm:
.Lspinlock:
    movl $1, %eax
    xchgl %eax, (%rdi)
    testl %eax, %eax
    jz .Lspinlock_acquired
    pause
    jmp .Lspinlock
.Lspinlock_acquired:
    ret

.global unlock_asm
.type unlock_asm, @function
unlock_asm:
    movl $0, (%rdi)
    ret

.global run_domain
run_domain:
    mov %rsp, %gs:CPU_SCHEDRESUME
    swapgs

    mov %rdi, %rbx
    lea SS_FXSAVE(%rbx), %rax
    fxrstor (%rax)

    push SS_SS(%rbx)
    push SS_RSP(%rbx)
    push SS_RFLAGS(%rbx)
    push SS_CS(%rbx)
    push SS_RIP(%rbx)

    mov SS_RAX(%rbx), %rax
    mov SS_RCX(%rbx), %rcx
    mov SS_RDX(%rbx), %rdx
    mov SS_RSI(%rbx), %rsi
    mov SS_RDI(%rbx), %rdi
    mov SS_RBP(%rbx), %rbp
    mov SS_R8(%rbx),  %r8
    mov SS_R9(%rbx),  %r9
    mov SS_R10(%rbx), %r10
    mov SS_R11(%rbx), %r11
    mov SS_R12(%rbx), %r12
    mov SS_R13(%rbx), %r13
    mov SS_R14(%rbx), %r14
    mov SS_R15(%rbx), %r15
    mov SS_RBX(%rbx), %rbx
    iretq

.global run_abort
run_abort:
    mov %rdi, %rsp
    ret
