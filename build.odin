package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

BUILD_DIR :: "build-dir"

BUILD_BOOTLOADER :: #config(BUILD_BOOTLOADER, true)
BUILD_KERNEL :: #config(BUILD_KERNEL, true)
BUILD_ADAM :: #config(BUILD_ADAM, true)

main :: proc() {
	os.remove_all(BUILD_DIR)
	os.make_directory_all(BUILD_DIR)

	when ODIN_DEBUG do run_tests()

	when BUILD_BOOTLOADER do build_bootloader()
	when BUILD_KERNEL do build_kernel()
	when BUILD_ADAM do build_adam()

}

run_tests :: proc() {
	exec([]string{"odin", "test", "kernel/pmm", "-debug", "-out:build-dir/pmm-tests"})
}

build_bootloader :: proc() {
	bootDir, _ := filepath.join({BUILD_DIR, "boot"})
	os.make_directory_all(bootDir)
	os.make_directory_all("diskimg/EFI/BOOT")

	objOut, _ := filepath.join({bootDir, "efi_boot.o"})
	bootFlags := []string {
		"-vet-shadowing",
		"-target:freestanding_amd64_win64",
		"-build-mode:obj",
		"-no-entry-point",
		"-disable-red-zone",
		"-define:UEFI_BUILD=true",
	}

	odin_build("uefi", objOut, bootFlags)

	objs := collect_objs(bootDir)
	linkCmd := make([dynamic]string, context.temp_allocator)
	append(
		&linkCmd,
		"lld-link",
		"-subsystem:efi_application",
		"-entry:efi_main",
		"-out:diskimg/EFI/BOOT/BOOTX64.EFI",
	)
	for o in objs do append(&linkCmd, o)
	exec(linkCmd[:])
}
build_adam :: proc() {
	os.make_directory_all("diskimg")

	adamDir, _ := filepath.join({BUILD_DIR, "adam"})
	os.make_directory_all(adamDir)

	asmOut, _ := filepath.join({adamDir, "syscall_exit.o"})
	exec(
		[]string {
			"clang",
			"-target",
			"x86_64-unknown-none-elf",
			"-c",
			"lib/syscalls/syscalls.asm",
			"-o",
			asmOut,
		},
	)
	objOut, _ := filepath.join({adamDir, "adam.o"})
	odin_build(
		"adam",
		objOut,
		{
			"-reloc-mode:static",
			"-vet-shadowing",
			"-target:freestanding_amd64_sysv",
			"-no-entry-point",
			"-no-crt",
			"-build-mode:obj",
		},
	)

	objs := collect_objs(adamDir)
	adamOut, _ := filepath.join({"diskimg", "adam.elf"})

	linkCmd := make([dynamic]string, context.temp_allocator)
	append(&linkCmd, "ld.lld", "--entry=_start", "-o", adamOut)
	for o in objs do append(&linkCmd, o)
	exec(linkCmd[:])

}
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
collect_objs :: proc(dir: string) -> [dynamic]string {
	d, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		panic(fmt.tprintf("failed to read directory %s: %s", dir, os.error_string(err)))
	}
	out := make([dynamic]string, context.temp_allocator)
	for f in d {
		if strings.has_suffix(f.name, ".o") || strings.has_suffix(f.name, ".obj") {
			append(&out, fmt.tprintf("%s/%s", dir, f.name))
		}
	}
	return out
}

odin_build :: proc(pkg: string, out: string, extra: []string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", pkg)
	when ODIN_DEBUG {
		append(&cmd, "-debug", "-o:minimal")
	} else {
		append(&cmd, "-o:aggressive")
	}
	for e in extra do append(&cmd, e)
	append(&cmd, fmt.tprintf("-out:%s", out))
	exec(cmd[:])
}

exec :: proc(command: []string) {
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{working_dir = ".", command = command},
		allocator = context.temp_allocator,
	)
	if err != nil {
		panic(fmt.tprintf("error executing %v: %s", command, os.error_string(err)))
	}
	msg := fmt.tprintf("%s%s", string(stdout), string(stderr))
	if state.exit_code != 0 {
		panic(fmt.tprintf("command failed %v: %s", command, msg))
	}
	fmt.print(msg)
}
