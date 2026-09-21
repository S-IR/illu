.global gs_read_u64
gs_read_u64:
    movq %gs:(%rcx), %rax
    ret
