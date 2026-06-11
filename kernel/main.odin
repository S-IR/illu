package kernel
import ah "../asm_helpers"
import "../uefi"
import "base:runtime"
import "print"
QEMU_TEST :: true


@(export)
kernel_main :: proc "sysv" (params: ^uefi.KernelParams) {
	context = runtime.default_context()
	// kernelParams := params^
	// ah.kernel_start_setup()
	print.serial_init_asm()
	print.serial_writeln("kernel base!")

	print.serial_write_hex(params.kernelImg.base)
	print.serial_writeln("kernel entry!")

	print.serial_write_hex(params.kernelImg.entry)
	print.serial_writeln("illu kernel starting!")

	print.serial_write_hex(params.kernelImg.end)
	print.serial_writeln("kernel end!")

	for {}
}
