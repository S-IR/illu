#!/bin/bash
odin run build.odin -file -debug;
qemu-system-x86_64 -enable-kvm -machine q35,accel=kvm -cpu host -m 512m \
  -drive if=pflash,format=raw,readonly=on,file=ovmf/ovmf_code.fd \
  -drive if=pflash,format=raw,file=ovmf/ovmf_vars.fd \
  -drive format=raw,file=fat:rw:diskimg,if=ide \
  -serial stdio -s -S &
QEMU_PID=$!
gdb -q -ex "file diskimg/kernel.elf" -ex "target remote :1234" -ex "hbreak kernel_main" -ex "c"
kill $QEMU_PID 2>/dev/null
