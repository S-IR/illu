odin run build.odin -file -debug

qemu-system-x86_64 -m 512m \
  -nodefaults \
  -accel kvm \
  -cpu host \
  -smp 4 \
  -no-reboot \
  -device VGA \
  -drive if=pflash,format=raw,readonly=on,file=ovmf/ovmf_code.fd \
  -drive if=pflash,format=raw,file=ovmf/ovmf_vars.fd \
  -drive format=raw,file=fat:rw:diskimg,if=ide \
  -serial stdio \
  -nographic \
  -no-shutdown \
  -s -S &

QEMU_PID=$!
trap "kill $QEMU_PID 2>/dev/null" EXIT

gdb -q \
  -ex "file diskimg/kernel.elf" \
  -ex "target remote localhost:1234" \
  -ex "hbreak kernel_start_setup" \
  -ex "continue"