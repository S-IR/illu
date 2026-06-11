package print

import ah "../../asm_helpers"
kassert :: proc(
	condition: bool,
	message := #caller_expression(condition),
	loc := #caller_location,
) {
	when ODIN_TEST {
		assert(condition, message, loc)
	} else when ODIN_DEBUG {
		if !condition {
			serial_write("KASSERT failed: ")
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
