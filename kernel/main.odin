package kernel
import ah "../asm_helpers"
import "../uefi"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"
QEMU_TEST :: true

KERNEL_STACK_SIZE :: 64 * mem.Kilobyte

@(export)
kernel_main :: proc "sysv" (params: ^uefi.KernelParams) {
	// ah.kernel_start_setup()
	// kernelParams := params^
	// ah.kernel_start_setup()
	context = runtime.default_context()
	context.assertion_failure_proc = print.kassert_failure_handler
	// assert(false, "what")
	print.serial_init_asm()
	print.serial_writeln("illu kernel alive!")
	print.serial_writeln("params ptr:")
	print.serial_write_hex(u64(uintptr(params)))
	print.serial_writeln("")
	print.serial_writeln("memoryMapSize:")
	print.serial_write_u64(params.memoryMapSize)
	print.serial_writeln("")
	print.serial_writeln("memoryMapDescSize:")
	print.serial_write_u64(params.memoryMapDescSize)
	print.serial_writeln("")
	gdt_tss_init()
	idt_init()

	lapic_init()
	pmm.men_init(
		memoryMap = params.memoryMap,
		memoryMapSize = params.memoryMapSize,
		memoryMapDescSize = params.memoryMapDescSize,
		kernelImg = params.kernelImg,
	)
	for {}
}
