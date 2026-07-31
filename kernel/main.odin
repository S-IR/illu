package kernel

import ah "../asm_helpers"
import "../uefi"
import "base:runtime"
import "core:mem"
import "pmm"
import "print"

QEMU_TEST :: true
KERNEL_STACK_SIZE :: 64 * mem.Kilobyte

IA32_FS_BASE :: 0xC0000100
BOOT_TLS_SIZE :: 4096

tempArena: mem.Arena
gBootTls: [BOOT_TLS_SIZE]u8

rootGDT: GDT
gBootTlsEnd: u64
@(export)
kernel_main :: proc "sysv" (params: ^uefi.KernelParams) {
	context = runtime.default_context()
	context.assertion_failure_proc = print.kassert_failure_handler

	print.serial_init_asm()
	print.serial_writeln("illu kernel alive!")


	gdt_tss_init(&rootGDT)

	idt_init()
	lapic_init()
	pmm.men_init(
		memoryMap = params.memoryMap,
		memoryMapSize = params.memoryMapSize,
		memoryMapDescSize = params.memoryMapDescSize,
		kernelImg = params.kernelImg,
		adamImg = params.adamImg,
	)

	context.allocator = pmm.heap_allocator()
	gBootTlsEnd = u64(uintptr(&gBootTls)) + len(gBootTls)
	ah.wrmsr_asm(IA32_FS_BASE, gBootTlsEnd)

	tempBuf := make([]u8, 64 * mem.Kilobyte)
	print.kassert(raw_data(tempBuf) != nil, "temp arena alloc failed")
	mem.arena_init(&tempArena, tempBuf)
	gKernelCtx = context

	sched_init(params.rsdp)
	adam_init(params.adamImg)


	sched_start()
}
