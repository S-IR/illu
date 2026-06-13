
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

.section .text

.global kernel_start_setup
// SDM Vol 2A "CLI": clears RFLAGS.IF — no interrupts before IDT is loaded (would triple-fault).
// SDM Vol 2A "CLD": clears RFLAGS.DF — Odin runtime memset/memcpy use rep movs which require DF=0.
kernel_start_setup:
    cli
    cld
    ret

.global serial_init_asm
// NS16550A UART. COM1 base = 0x3F8 (IBM PC standard). Reg offsets: PC16550D datasheet §3.
// Port map: +0=THR/RBR/DLL, +1=IER/DLH, +2=FCR/IIR, +3=LCR, +5=LSR.
// Baud: clock=1843200 Hz, divisor=CLOCK/(16*baud). Divisor 3 → 38400 baud.
serial_init_asm:
    mov $0x3F9, %dx       // COM1+1 = IER: disable all UART interrupts (we poll LSR)
    mov $0x00, %al
    out %al, %dx

    mov $0x3FB, %dx       // COM1+3 = LCR: DLAB=1 (bit 7) → next writes go to DLL/DLH
    mov $0x80, %al
    out %al, %dx

    mov $0x3F8, %dx       // COM1+0 = DLL (DLAB=1): divisor low = 3 → 38400 baud
    mov $0x03, %al
    out %al, %dx

    mov $0x3F9, %dx       // COM1+1 = DLH (DLAB=1): divisor high = 0
    mov $0x00, %al
    out %al, %dx

    mov $0x3FB, %dx       // COM1+3 = LCR: 0x03 = 8 data bits, no parity, 1 stop (8N1). DLAB cleared.
    mov $0x03, %al
    out %al, %dx

    mov $0x3FA, %dx       // COM1+2 = FCR: 0xC7 = enable FIFO, clear TX+RX FIFOs, 14-byte RX trigger
    mov $0xC7, %al
    out %al, %dx
    ret

.global serial_write_byte_asm
serial_write_byte_asm:
    push %rdi
1:
    mov $0x3FD, %dx       // COM1+5 = LSR: bit 5 (THRE) = TX holding register empty → safe to write
    in %dx, %al
    test $0x20, %al
    jz 1b
    pop %rdi
    mov $0x3F8, %dx       // COM1+0 = THR (DLAB=0): write byte to transmit holding register
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
// SDM Vol 3A §3.4.2: CS can only be reloaded via far jmp/call/ret — not mov.
// We do a far return: push CS selector (0x08 = KERNEL_CS) then RIP, then lretq.
// DS/ES/SS loaded with 0x10 (KERNEL_DS). FS zeroed (no TLS yet); GS used for per-CPU later.
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


// SDM Vol 2A "LTR — Load Task Register": loads TR with the TSS selector, marks descriptor busy.
// Must call after GDT is loaded. Required for IST stacks and RSP0 to work on interrupts.
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
