#!/bin/bash
odin run build.odin -file -debug
qemu-system-x86_64 -enable-kvm -cpu qemu64 -m 512m \
  -nodefaults \
  -device VGA \
  -drive if=pflash,format=raw,readonly=on,file=ovmf/ovmf_code.fd \
  -drive if=pflash,format=raw,file=ovmf/ovmf_vars.fd \
  -drive format=raw,file=fat:rw:diskimg,if=ide \
  -serial stdio \
  -nographic
