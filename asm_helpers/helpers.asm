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
    or $0x620, %eax        // PAE | OSFXSR | OSXMMEXCPT (was 0x20)
    mov %eax, %cr4
    mov $0xC0000080, %ecx
    rdmsr
    or $0x900, %eax        // LME | NXE (was 0x100) - must match BSP's enable_nxe()
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

.global enable_write_protect_kernel
enable_write_protect_kernel:
    mov %cr0, %rax
    or $0x10000, %rax
    mov %rax, %cr0
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

.global syscall_entry
syscall_entry:
    swapgs
    mov %rsp, %gs:16
    mov %gs:8, %rsp
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
    mov %gs:16, %rsp
    swapgs
    sysretq

.global idle_loop
idle_loop:
    sti
    call domain_pick_and_enter
    cli
    lea %gs:41, %rax
    movl $0, %ecx
    movl $0, %edx
    monitor
    movzbq %gs:40, %rax
    xorl %ecx, %ecx
    xorl %edx, %edx
    mwait
    jmp idle_loop

.global gs_read_cpustate
gs_read_cpustate:
    movq %gs:0, %rax
    ret

.global thread_save_and_switch_to
thread_save_and_switch_to:
    mov %rsp, (%rdi)
    mov 40(%rsi), %rax
    mov %rax, %gs:8
    mov (%rsi), %rsp
    ret

.global thread_load_and_switch_to
thread_load_and_switch_to:
    mov 40(%rdi), %rax
    mov %rax, %gs:8
    mov (%rdi), %rsp
    ret

.global thread_start_idle_loop
thread_start_idle_loop:
    movq %gs:8, %rsp     
    movq %gs:8, %rax      
    movq %gs:24, %rcx    
    movq %rax, (%rcx)    
    jmp idle_loop

.global enter_userspace
enter_userspace:
    // rdi = target user rip (arg1), rsi = target user rsp (arg2) — SysV ABI
    swapgs                  // stash kernel CpuState ptr (GS_BASE) into KERNEL_GS_BASE,
                              // mirrors the swapgs pair already used in syscall_entry
    push $0x23               // SS: UserData selector (GDT index 4, 4<<3=0x20) | RPL3 (0x20|3)
    push %rsi                 // RSP = user stack top passed in by caller
    pushfq
    pop %rax
    or $0x200, %rax           // force IF (bit 9) on — user thread must run with interrupts enabled
    push %rax                 // RFLAGS for the target context
    push $0x2B                // CS: UserCode64 selector (GDT index 5, 5<<3=0x28) | RPL3 (0x28|3)
    push %rdi                 // RIP = user entry point passed in by caller
    iretq                     // pops RIP,CS,RFLAGS,RSP,SS — CS.RPL=3 triggers the ring0->ring3 switch

.global user_thread_entry
user_thread_entry:
    popq %rdi
    popq %rsi
    call enter_userspace
    hlt