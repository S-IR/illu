package print

import ah "../../asm_helpers"
import "core:fmt"

when !ODIN_TEST {
	serial_write :: proc "contextless" (s: string) {
		for i := 0; i < len(s); i += 1 do ah.serial_write_byte_asm(s[i])
	}

	serial_write_hex :: proc(value: u64) {
		serial_write("0x")
		for i := 60; i >= 0; i -= 4 {
			nibble := (value >> uint(i)) & 0xF
			if nibble < 10 {
				ah.serial_write_byte_asm(u8('0') + u8(nibble))
			} else {
				ah.serial_write_byte_asm(u8('a') + u8(nibble) - 10)
			}
		}
	}

	serial_write_u64 :: proc(value: u64) {
		if value == 0 {
			ah.serial_write_byte_asm('0')
			return
		}
		buf: [20]u8
		n := 0
		v := value
		for v > 0 {
			buf[n] = u8('0') + u8(v % 10)
			n += 1
			v /= 10
		}
		for i := n - 1; i >= 0; i -= 1 do ah.serial_write_byte_asm(buf[i])
	}

	serial_writeln :: proc "contextless" (s: string) {
		serial_write(s)
		ah.serial_write_byte_asm('\r')
		ah.serial_write_byte_asm('\n')
	}

	serial_init_asm :: proc "contextless" () {ah.serial_init_asm()}
	serial_write_byte_asm :: proc "contextless" (c: u8) {ah.serial_write_byte_asm(c)}
	serial_write_bytes :: proc "contextless" (ptr: [^]u8, len: u64) {
		for i in 0 ..< len do ah.serial_write_byte_asm(ptr[i])
	}

} else {
	serial_write :: proc(s: string) {fmt.print(s)}
	serial_write_hex :: proc(v: u64) {fmt.printf("0x%016x", v)}
	serial_write_u64 :: proc(v: u64) {fmt.print(v)}
	serial_writeln :: proc(s: string) {fmt.println(s)}
	serial_init_asm :: proc() {}
	serial_write_byte_asm :: proc(c: u8) {}
	serial_write_bytes :: proc(ptr: [^]u8, len: u64) {fmt.print(string(ptr[:len]))}
}
