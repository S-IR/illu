package build

import "core:os"
import "core:path/filepath"

build_kernel :: proc() {
	os.make_directory_all("diskimg")

	kernelDir, _ := filepath.join({BUILD_DIR, "kernel"})
	os.make_directory_all(kernelDir)

	asmOut, _ := filepath.join({kernelDir, "asm_helpers.o"})
	exec(
		[]string {
			"clang",
			"-target",
			"x86_64-unknown-none-elf",
			"-c",
			"asm_helpers/helpers.asm",
			"-o",
			asmOut,
		},
	)

	objOut, _ := filepath.join({kernelDir, "kernel.o"})
	odin_build(
		"kernel",
		objOut,
		{
			"-reloc-mode:static",
			"-vet-shadowing",
			"-target:freestanding_amd64_sysv",
			"-no-entry-point",
			"-no-crt",
			"-build-mode:obj",
			"-define:KERNEL_BUILD=true",
		},
	)

	objs := collect_objs(kernelDir)
	kernelOut, _ := filepath.join({"diskimg", "kernel.elf"})

	linkCmd := make([dynamic]string, context.temp_allocator)
	append(
		&linkCmd,
		"ld.lld",
		"--image-base=0x100000",
		"--entry=kernel_start_setup",
		"-o",
		kernelOut,
	)
	for o in objs do append(&linkCmd, o)
	exec(linkCmd[:])
}
