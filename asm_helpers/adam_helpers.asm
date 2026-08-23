.text

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

.global cpu_pause
cpu_pause:
    pause
    ret
