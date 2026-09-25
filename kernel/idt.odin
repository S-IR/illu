package kernel
import ah "../asm_helpers"
import "../lib/userschedule"
import "base:intrinsics"
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
#assert(size_of(IdtEntry) == 16)
#assert(offset_of(IdtEntry, offsetLow) == 0)
#assert(offset_of(IdtEntry, selector) == 2)
#assert(offset_of(IdtEntry, ist) == 4)
#assert(offset_of(IdtEntry, flags) == 5)
#assert(offset_of(IdtEntry, offsetMid) == 6)
#assert(offset_of(IdtEntry, offsetHigh) == 8)
#assert(offset_of(IdtEntry, reserved) == 12)

idt: [256]IdtEntry
GIDTDescriptor: ah.X86TableDescriptor

VECTOR_NMI :: 2
VECTOR_DOUBLE_FAULT :: 8
VECTOR_MACHINE_CHECK :: 18

idt_init :: proc() {
	for isrTable, i in ah.isr_table {
		ist: u8 = 0
		switch i {
		case VECTOR_NMI, VECTOR_DOUBLE_FAULT, VECTOR_MACHINE_CHECK:
			ist = 1
		}
		idt_set_entry(i, u64(isrTable), ist)
	}
	for irqTable, i in ah.irq_stub_table {
		idt_set_entry(32 + i, u64(irqTable))
	}

	GIDTDescriptor.base = u64(uintptr(&idt))
	GIDTDescriptor.limit = u16(size_of(idt) - 1)
	ah.lidt_asm(&GIDTDescriptor)
	print.serial_writeln("idt: loaded")


}

IdtAccess :: bit_field u8 {
	gateType: u8   | 4, // 0xE = interrupt gate
	ring3:    bool | 1, // 0 = system
	dpl:      u8   | 2,
	present:  bool | 1,
}

idt_set_entry :: proc(index: int, handler: u64, ist: u8 = 0) {
	assert(index >= 0 && index < 256, "idt_set_entry: index out of range")
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
	fx:                 [512]u8,
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
#assert(size_of(InterruptFrame) == 688)
#assert(size_of(InterruptFrame) % 16 == 0)
#assert(offset_of(InterruptFrame, rax) == 512)
#assert(offset_of(InterruptFrame, r15) == 624)
#assert(offset_of(InterruptFrame, interruptNumber) == 632)
#assert(offset_of(InterruptFrame, error_code) == 640)
#assert(offset_of(InterruptFrame, rip) == 648)
#assert(offset_of(InterruptFrame, cs) == 656)
#assert(offset_of(InterruptFrame, rflags) == 664)
#assert(offset_of(InterruptFrame, rsp) == 672)
#assert(offset_of(InterruptFrame, ss) == 680)
#assert(offset_of(InterruptFrame, rax) == offset_of(userschedule.UserSaveArea, rax))
#assert(offset_of(InterruptFrame, r15) == offset_of(userschedule.UserSaveArea, r15))
#assert(userschedule.SAVE_AREA_FX_RESERVED == 464)

interrupt_frame_from_user :: #force_inline proc "contextless" (frame: ^InterruptFrame) -> bool {
	return (frame.cs & 3) == 3
}


@(export)
exception_handler :: proc "c" (frame: ^InterruptFrame) {
	userMode := interrupt_frame_from_user(frame)
	if userMode {
		kernel_switch_cr3()
	}

	context = gKernelCtx
	if frame.interruptNumber == VECTOR_APIC_TIMER {
		lapic_send_eoi()
		if userMode do grant_preempt(gs_read_cpustate(), frame)
		return
	}

	if frame.interruptNumber >= 32 {
		irq_handler(frame)
		if userMode {
			cpu := gs_read_cpustate()
			if intrinsics.atomic_load(&cpu.currentGrant.weight) == 0 do grant_exit()
			domain_switch_cr3(cpu.currentGrant.domain)
		}
		return
	}
	if !userMode && user_access_faulted(frame) {
		print.serial_write("domain fault: save area ")
		print.serial_write(exceptionNames[frame.interruptNumber])
		print.serial_writeln(", grant dropped")
		grant_exit()
	}
	if userMode {
		print.serial_write("domain fault: ")
		print.serial_write(exceptionNames[frame.interruptNumber])
		print.serial_write(" at rip=")
		print.serial_write_hex(frame.rip)
		print.serial_write(" cr2=")
		print.serial_write_hex(ah.read_cr2())
		print.serial_write(" err=")
		print.serial_write_hex(frame.error_code)
		print.serial_write(" domain.pml4=")
		print.serial_write_hex(gs_read_cpustate().currentGrant.domain.pml4)
		print.serial_writeln("")
		grant_exit()
	}

	name := exceptionNames[frame.interruptNumber]
	print.serial_writeln("")
	print.serial_writeln("======== KERNEL EXCEPTION ========")
	print.serial_write("vector:  ")
	print.serial_write_u64(frame.interruptNumber)
	print.serial_write("  (")
	print.serial_write(name)
	print.serial_writeln(")")

	print.serial_write("rip:     ")
	print.serial_write_hex(frame.rip)
	print.serial_writeln("")

	print.serial_write("cs:      ")
	print.serial_write_hex(frame.cs)
	print.serial_write("   (ring ")
	print.serial_write_u64(frame.cs & 3)
	print.serial_writeln(")")

	print.serial_write("rsp:     ")
	print.serial_write_hex(frame.rsp)
	print.serial_writeln("")
	print.serial_write("rflags:  ")
	print.serial_write_hex(frame.rflags)
	print.serial_writeln("")
	print.serial_write("error:   ")
	print.serial_write_hex(frame.error_code)
	print.serial_writeln("")

	if frame.interruptNumber == 14 {
		cr2 := ah.read_cr2()
		print.serial_write("cr2:     ")
		print.serial_write_hex(cr2)
		print.serial_writeln("")

		ec := frame.error_code
		print.serial_write("pf info: ")
		print.serial_write(ec & 1 != 0 ? "PROTECTION-VIOLATION" : "NOT-PRESENT")
		print.serial_write(" | ")
		print.serial_write(ec & 2 != 0 ? "WRITE" : "READ")
		print.serial_write(" | ")
		print.serial_write(ec & 4 != 0 ? "USER" : "SUPERVISOR")
		if ec & 8 != 0 do print.serial_write(" | RESERVED-BIT-SET")
		if ec & 16 != 0 do print.serial_write(" | INSTR-FETCH")
		print.serial_writeln("")

		if cr2 == 0 {
			print.serial_writeln("        cr2=0 -> likely a nil pointer dereference")
		}
	}

	print.serial_writeln("--- general purpose registers ---")
	print_reg("rax", frame.rax); print_reg("rbx", frame.rbx)
	print_reg("rcx", frame.rcx); print_reg("rdx", frame.rdx)
	print_reg("rsi", frame.rsi); print_reg("rdi", frame.rdi)
	print_reg("rbp", frame.rbp)
	print_reg("r8 ", frame.r8); print_reg("r9 ", frame.r9)
	print_reg("r10", frame.r10); print_reg("r11", frame.r11)
	print_reg("r12", frame.r12); print_reg("r13", frame.r13)
	print_reg("r14", frame.r14); print_reg("r15", frame.r15)

	print.serial_writeln("===================================")
	ah.halt()
}

@(private)
print_reg :: proc "contextless" (name: string, val: u64) {
	print.serial_write(name)
	print.serial_write(": ")
	print.serial_write_hex(val)
	print.serial_writeln("")
}
irq_handler :: proc(frame: ^InterruptFrame) {
	v := int(frame.interruptNumber)
	switch v {
	case VECTOR_APIC_ERROR:
		print.serial_writeln("lapic: error fired")
	case VECTOR_APIC_THERMAL:
		print.serial_writeln("lapic: thermal fired")
	case VECTOR_APIC_LINT0:
		print.serial_writeln("lapic: lint0 fired")
	case VECTOR_APIC_LINT1:
		print.serial_writeln("lapic: lint1 fired")
	case VECTOR_APIC_IPI:
	case:
		print.serial_write("lapic: unhandled irq=")
		print.serial_write_hex(u64(v))
		print.serial_writeln("")
	}

	lapic_send_eoi()
}

user_access_faulted :: proc "contextless" (frame: ^InterruptFrame) -> bool {
	VECTOR_GENERAL_PROTECTION :: 13
	VECTOR_PAGE_FAULT :: 14
	if frame.interruptNumber != VECTOR_GENERAL_PROTECTION && frame.interruptNumber != VECTOR_PAGE_FAULT do return false
	begin := u64(uintptr(rawptr(user_access_begin)))
	end := u64(uintptr(rawptr(user_access_end)))
	return frame.rip >= begin && frame.rip < end
}
