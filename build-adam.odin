package build

import "core:os"
import "core:path/filepath"

build_adam :: proc() {
	os.make_directory_all("diskimg")

	adamDir, _ := filepath.join({BUILD_DIR, "adam"})
	os.make_directory_all(adamDir)

	asmOut, _ := filepath.join({adamDir, "adam_helpers.o"})
	exec(
		[]string {
			"clang",
			"-target",
			"x86_64-unknown-none-elf",
			"-c",
			"asm_helpers/adam_helpers.asm",
			"-o",
			asmOut,
		},
	)

	syscallAsmOut, _ := filepath.join({adamDir, "syscall_exit.o"})
	exec(
		[]string {
			"clang",
			"-target",
			"x86_64-unknown-none-elf",
			"-c",
			"lib/syscalls/syscalls.asm",
			"-o",
			syscallAsmOut,
		},
	)
	objOut, _ := filepath.join({adamDir, "adam.o"})
	odin_build(
		"adam",
		objOut,
		{
			"-reloc-mode:pic",
			"-vet-shadowing",
			"-target:freestanding_amd64_sysv",
			"-no-entry-point",
			"-no-crt",
			"-disable-red-zone",
			"-build-mode:obj",
		},
	)

	objs := collect_objs(adamDir)
	adamOut, _ := filepath.join({"diskimg", "adam.elf"})

	linkCmd := make([dynamic]string, context.temp_allocator)
	append(&linkCmd, "ld.lld", "-pie", "--entry=_start", "-o", adamOut)
	for o in objs do append(&linkCmd, o)
	exec(linkCmd[:])
}
