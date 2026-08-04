.global syscall_exit
syscall_exit:
    xor %eax, %eax
    syscall
1:  hlt
    jmp 1b