.section .data
.global irq_stub_table
irq_stub_table:
    .quad irq32, irq33, irq34, irq35, irq36, irq37, irq38, irq39
    .quad irq40, irq41, irq42, irq43, irq44, irq45, irq46, irq47
    .quad irq48, irq49, irq50, irq51, irq52, irq53, irq54, irq55
    .quad irq56, irq57, irq58, irq59, irq60, irq61, irq62, irq63
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
    call syscall_enter_kernel
    push %rax
    push %rcx
    push %r11
    mov %r8,  %r9
    mov %r10, %r8
    mov %rdx, %rcx
    mov %rsi, %rdx
    mov %rdi, %rsi
    mov %rax, %rdi
    call syscall_dispatch
    pop %r11
    pop %rcx
    pop %rdx
    push %rax
    mov %rdx, %rdi
    call syscall_restore_domain
    pop %rax
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
    hlt                         
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
