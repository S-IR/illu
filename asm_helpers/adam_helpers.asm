.include "lib/syscalls/user_resume.inc"

.text

.global _start
_start:
    cmp $RESUME_REASON, %rdi
    jne adam_entry
    USER_RESUME_BODY

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

.global cpu_has_avx
cpu_has_avx:
    push %rbx
    mov $1, %eax
    xor %ecx, %ecx
    cpuid
    xor %eax, %eax
    bt $28, %ecx
    jnc 1f
    bt $27, %ecx
    jnc 1f
    xor %ecx, %ecx
    xgetbv
    and $6, %eax
    cmp $6, %eax
    sete %al
    movzbl %al, %eax
1:
    pop %rbx
    ret

.macro AVX_CHECK reg, offset
    vxorps \offset(%rsi), %ymm\reg, %ymm15
    vptest %ymm15, %ymm15
    jnz .Lavx_fail
.endm

# rdi = status {iterations, failures}, rsi = 15 x 32-byte patterns
.global avx_check_worker
avx_check_worker:
.Lavx_reload:
    vmovdqu 0(%rsi), %ymm0
    vmovdqu 32(%rsi), %ymm1
    vmovdqu 64(%rsi), %ymm2
    vmovdqu 96(%rsi), %ymm3
    vmovdqu 128(%rsi), %ymm4
    vmovdqu 160(%rsi), %ymm5
    vmovdqu 192(%rsi), %ymm6
    vmovdqu 224(%rsi), %ymm7
    vmovdqu 256(%rsi), %ymm8
    vmovdqu 288(%rsi), %ymm9
    vmovdqu 320(%rsi), %ymm10
    vmovdqu 352(%rsi), %ymm11
    vmovdqu 384(%rsi), %ymm12
    vmovdqu 416(%rsi), %ymm13
    vmovdqu 448(%rsi), %ymm14
.Lavx_loop:
    lock incq (%rdi)
    AVX_CHECK 0, 0
    AVX_CHECK 1, 32
    AVX_CHECK 2, 64
    AVX_CHECK 3, 96
    AVX_CHECK 4, 128
    AVX_CHECK 5, 160
    AVX_CHECK 6, 192
    AVX_CHECK 7, 224
    AVX_CHECK 8, 256
    AVX_CHECK 9, 288
    AVX_CHECK 10, 320
    AVX_CHECK 11, 352
    AVX_CHECK 12, 384
    AVX_CHECK 13, 416
    AVX_CHECK 14, 448
    jmp .Lavx_loop
.Lavx_fail:
    lock incq 8(%rdi)
    jmp .Lavx_reload
