#!/bin/bash
set -e
odin run build.odin -file -debug

qemu-system-x86_64 \
  -machine q35,accel=kvm,smm=off \
  -cpu host,+rdrand,+pcid,+invpcid,+tsc-deadline,+pdpe1gb,+hypervisor \
  -smp 2,sockets=1,cores=2,threads=1 \
  -m 512m \
  -no-reboot \
  -overcommit mem-lock=off \
  -overcommit cpu-pm=on \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=ovmf_vars.fd \
  -drive format=raw,file=fat:rw:diskimg,if=virtio,cache=writeback \
  -drive id=nvme0,file=build-dir/nvme.img,if=none,format=raw,cache=writethrough,discard=unmap,aio=native \
  -device nvme,drive=nvme0,serial=osdrive \
  -drive id=nvme1,file=build-dir/nvme2.img,if=none,format=raw,cache=writethrough,discard=unmap,aio=native \
  -device nvme,drive=nvme1,serial=osdrive2 \
  -netdev user,id=net0,hostfwd=tcp::1234-:1234 \
  -device e1000e,netdev=net0 \
  -object filter-dump,id=f0,netdev=net0,file=/tmp/net.pcap \
  -serial stdio \
  -gdb tcp::1235 \
  -S &

while ! nc -z 127.0.0.1 1235; do sleep 0.1; done
