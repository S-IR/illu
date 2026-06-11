
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
