package kernel

import ah "../asm_helpers"
import "../lib/alloc"
import "../uefi"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"

gdtBeforeSched: GDT

@(export)
kernel_main :: proc "sysv" (bootParams: ^uefi.KernelParams) {
	context = runtime.default_context()
	context.assertion_failure_proc = print.kassert_failure_handler
	context.random_generator = {}
	params := bootParams^

	print.serial_init_asm()
	print.serial_writeln("illu kernel alive!")

	cpuid_init_meltdown_check()
	cpuid_init_speculation_mitigations()
	cpuid_init_pcid()
	cpuid_init_xsave()

	gdt_tss_fill(&gdtBeforeSched)
	gdt_tss_load(&gdtBeforeSched)

	idt_init()
	lapic_init()
	pmm.men_init(
		&kernelState.pmm,
		memoryMap = params.memoryMap,
		memoryMapSize = params.memoryMapSize,
		memoryMapDescSize = params.memoryMapDescSize,
		kernelImg = params.kernelImg,
		adamImg = params.adamImg,
		reserved = {mem.slice_to_bytes(params.apicIds), mem.slice_to_bytes(params.pciDevices)},
		globalKernel = !cpuMeltdownVulnerable,
		has1GBPages = cpuid_has_1gb_pages(),
	)

	kernelState.heap.pmm = &kernelState.pmm
	context.allocator = alloc.heap_allocator(&kernelState.heap)
	gKernelCtx = context

	cpus_init(pmm.phys_to_slice(params.apicIds))
	adam_init(params.adamImg, params.pciDevices)

	grant_loop()
}
