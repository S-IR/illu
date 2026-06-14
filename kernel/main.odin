package kernel
import ah "../asm_helpers"
import "../uefi"
import "base:runtime"
import "pmm"
import "print"
QEMU_TEST :: true


@(export)
kernel_main :: proc "sysv" (params: ^uefi.KernelParams) {
	// ah.kernel_start_setup()
	// kernelParams := params^
	// ah.kernel_start_setup()
	context = runtime.default_context()
	context.assertion_failure_proc = print.kassert_failure_handler
	print.serial_init_asm()
	print.serial_writeln("illu kernel alive!")

	gdt_tss_init()
	context = runtime.default_context()
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
