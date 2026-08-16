package print

import ah "../../asm_helpers"
import "base:runtime"

when ODIN_TEST {
	kassert :: proc "contextless" (
		condition: bool,
		message := #caller_expression(condition),
		loc := #caller_location,
	) {
		context = runtime.default_context()
		assert(condition, message, loc)
	}
} else {
	kassert :: proc "contextless" (
		condition: bool,
		message := #caller_expression(condition),
		loc := #caller_location,
	) {
		when ODIN_DEBUG {
			if !condition {
				print_assert_failure(message, loc)
				ah.halt()
			}
		}
	}
}

print_assert_failure :: proc "contextless" (message: string, loc: runtime.Source_Code_Location) {
	context = runtime.default_context()
	serial_write("KASSERT failed: ")
	serial_write(message)
	serial_write(" @ ")
	serial_write(loc.file_path)
	serial_write(":")
	serial_write_u64(u64(loc.line))
	serial_write(" in ")
	serial_writeln(loc.procedure)

	serial_writeln("stack trace:")
	rbp := ah.read_rbp()
	for i in u64(0) ..< 8 {
		if rbp < 0x1000 || rbp & 7 != 0 do break
		frame := (^u64)(uintptr(rbp))
		returnAddress := (^u64)(uintptr(rbp) + 8)
		serial_write("  #")
		serial_write_u64(i)
		serial_write(" rbp=")
		serial_write_hex(rbp)
		serial_write(" rip=")
		serial_write_hex(returnAddress^)
		serial_writeln("")
		next := frame^
		if next <= rbp do break
		rbp = next
	}
}

when !ODIN_TEST {
	kassert_failure_handler :: proc(
		prefix, message: string,
		loc: runtime.Source_Code_Location,
	) -> ! {
		serial_write("KASSERT failed: ")
		serial_write(prefix)
		serial_write(": ")
		serial_write(message)
		serial_write(" @ ")
		serial_write(loc.file_path)
		serial_write(":")
		serial_write_u64(u64(loc.line))
		serial_write(":")
		serial_write_u64(u64(loc.column))
		serial_write(" in ")
		serial_writeln(loc.procedure)
		ah.halt()
	}
}

kensure :: proc(
	condition: bool,
	message := #caller_expression(condition),
	loc := #caller_location,
) {
	when ODIN_TEST {
		assert(condition, message, loc)
	} else {
		if !condition {
			serial_write("KERNEL ENSURE FAILURE :( : ")
			serial_write(message)
			serial_write(" @ ")
			serial_write(loc.file_path)
			serial_write(":")
			serial_write_hex(u64(loc.line))
			serial_writeln("")
			ah.halt()
		}
	}
}
