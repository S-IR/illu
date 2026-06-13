package kernel
import ah "../asm_helpers"
import "base:runtime"
import "print"
// SDM Vol 3A §6.14.1 Figure 6-8: 16-byte 64-bit IDT gate descriptor layout.
// selector must be KERNEL_CS (0x08). ist=0 → use TSS.RSP0; ist=1..7 → use TSS.IST[ist-1].
// handler address split across offsetLow[15:0] / offsetMid[31:16] / offsetHigh[63:32].
IdtEntry :: struct #packed {
	offsetLow:  u16,
	selector:   u16,
	ist:        u8,
	flags:      u8,
	offsetMid:  u16,
	offsetHigh: u32,
	reserved:   u32,
}

idt: [256]IdtEntry
idtDesc: ah.X86TableDescriptor

idt_init :: proc() {
	for isrTable, i in ah.isr_table {
		idt_set_entry(i, u64(isrTable))
	}
	for irqTable, i in ah.irq_stub_table {
		idt_set_entry(32 + i, u64(irqTable))
	}

	idtDesc.base = u64(uintptr(&idt))
	idtDesc.limit = u16(size_of(idt) - 1)
	ah.lidt_asm(&idtDesc)
	// print.serial_writeln("idt: loaded")


}

IdtAccess :: bit_field u8 {
	gateType: u8   | 4, // 0xE = interrupt gate
	ring3:    bool | 1, // 0 = system
	dpl:      u8   | 2,
	present:  bool | 1,
}

idt_set_entry :: proc(index: int, handler: u64, ist: u8 = 0) {
	print.kassert(index >= 0 && index < 256, "idt_set_entry: index out of range")
	idt[index].offsetLow = u16(handler & 0xFFFF)
	idt[index].offsetMid = u16((handler >> 16) & 0xFFFF)
	idt[index].offsetHigh = u32(handler >> 32)
	KERNEL_CS :: u16(GDTEntryNames.KernelCode) << 3
	idt[index].selector = KERNEL_CS
	idt[index].ist = ist

	idt[index].flags = transmute(u8)IdtAccess {
		gateType = 0xE,
		ring3 = false,
		dpl = 0,
		present = true,
	}
	idt[index].reserved = 0
}


@(rodata)
exceptionNames := [32]string {
	"#DE divide error",
	"#DB debug",
	"#NMI",
	"#BP breakpoint",
	"#OF overflow",
	"#BR bound range",
	"#UD invalid opcode",
	"#NM device not available",
	"#DF double fault",
	"#CSO coprocessor segment overrun",
	"#TS invalid tss",
	"#NP segment not present",
	"#SS stack fault",
	"#GP general protection",
	"#PF page fault",
	"#reserved",
	"#MF x87 fpe",
	"#AC alignment check",
	"#MC machine check",
	"#XM simd fpe",
	"#VE virtualization",
	"#CP control protection",
	"#reserved",
	"#reserved",
	"#reserved",
	"#reserved",
	"#reserved",
	"#reserved",
	"#HV hypervisor",
	"#VC vmm comm",
	"#SX security",
	"#reserved",
}
// Layout mirrors exactly what the stack looks like when exception_handler is called.
// CPU auto-pushes (high→low on stack): SS, RSP, RFLAGS, CS, RIP — SDM Vol 3A §6.12.1.
// For error-code exceptions, CPU also pushes error_code before RIP.
// Our stubs push vector_number then jump to interrupt_dispatch which pushes all GPRs.
InterruptFrame :: struct #packed {
	rax, rbx, rcx, rdx: u64,
	rsi, rdi, rbp:      u64,
	r8, r9, r10, r11:   u64,
	r12, r13, r14, r15: u64,
	interruptNumber:    u64,
	error_code:         u64,
	rip:                u64,
	cs:                 u64,
	rflags:             u64,
	rsp:                u64,
	ss:                 u64,
}


@(export)
exception_handler :: proc "c" (frame: ^InterruptFrame) {
	context = runtime.default_context()
	if frame.interruptNumber >= 32 {
		irq_handler(frame)
		return
	}
	when ODIN_DEBUG {
		if frame.interruptNumber == 3 {
			print.serial_writeln("int3 caught")
			return
		}
	}
	// if frame.interruptNumber == 1 {
	// 	debug_exception_handler(frame)
	// 	return
	// }

	fromRing3 := frame.cs & 3 == 3

	when QEMU_TEST {
		name := exceptionNames[frame.interruptNumber]
		print.serial_write("EXCEPTION ")
		print.serial_write(name)
		print.serial_write(" at rip=")
		print.serial_write_hex(frame.rip)
		print.serial_write(" rsp=")
		print.serial_write_hex(frame.rsp)
		print.serial_write(" error=")
		print.serial_write_hex(frame.error_code)
		if frame.interruptNumber == 14 {
			print.serial_write(" cr2=")
			print.serial_write_hex(ah.read_cr2())
		}
		print.serial_writeln("")
	}

	ah.halt()
}
irq_handler :: proc(frame: ^InterruptFrame) {
	defer lapic_send_eoi()
	v := int(frame.interruptNumber)
	switch v {
	case VECTOR_APIC_TIMER:
	// scheduler tick goes here later
	case VECTOR_APIC_ERROR:
		print.serial_writeln("lapic: error fired")
	case VECTOR_APIC_THERMAL:
		print.serial_writeln("lapic: thermal fired")
	case VECTOR_APIC_LINT0:
		print.serial_writeln("lapic: lint0 fired")
	case VECTOR_APIC_LINT1:
		print.serial_writeln("lapic: lint1 fired")
	case:
		print.serial_write("lapic: unhandled irq=")
		print.serial_write_hex(u64(v))
		print.serial_writeln("")
	}
}
