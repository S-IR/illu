package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
BUILD_DIR :: "build-dir"
BOOT_DIR :: BUILD_DIR + "/bootloader"

BUILD_BOOTLOADER :: #config(BUILD_BOOTLOADER, true)
BUILD_KERNEL :: #config(BUILD_KERNEL, true)
INTEGRATION_TESTS :: #config(INTEGRATION_TESTS, false)


main :: proc() {
	os.remove_all(BUILD_DIR)
	osErr := os.make_directory_all(BUILD_DIR)
	if osErr != .Exist do ensure_os(osErr)
	when BUILD_BOOTLOADER do build_bootloader()
	when BUILD_KERNEL do build_kernel()
}
build_bootloader :: proc() {
	odin_build(
		"uefi",
		BOOT_DIR,
		"efi_boot.o",
		{
			"-vet-shadowing",
			"-target:freestanding_amd64_win64",
			"-build-mode:obj",
			"-no-entry-point",
			"-disable-red-zone",
		},
	)
	objs := collect_objs(BOOT_DIR, proc(n: string) -> bool {
			return strings.has_prefix(n, "efi_boot")
		})
	cmd := make([dynamic]string, context.temp_allocator)
	uefiPath, _ := filepath.join({"diskimg", "EFI", "BOOT", "BOOTX64.EFI"})
	osErr := os.make_directory_all(filepath.dir(uefiPath))
	if osErr != .Exist do ensure_os(osErr)

	append(
		&cmd,
		"lld-link",
		"-subsystem:efi_application",
		"-entry:efi_main",
		fmt.tprintf("-out:%s", uefiPath),
	)


	for o in objs do append(&cmd, o)
	exec(cmd[:])

}

build_kernel :: proc() {
	// when ODIN_DEBUG do exec({"odin", "test", "tests/", "-debug", "-o:minimal"})
	KERNEL_DIR, _ := filepath.join({BUILD_DIR, "kernel"})
	helpersPath, _ := filepath.join({"asm_helpers", "helpers.asm"})
	asm_build(helpersPath, KERNEL_DIR)

	// itDEFINE := "-define:INTEGRATION_TESTS=false"
	// when INTEGRATION_TESTS do itDEFINE = "-define:INTEGRATION_TESTS=true"

	odin_build(
		"kernel",
		KERNEL_DIR,
		"kernel.o",
		{
			"-reloc-mode:pic",
			"-vet-shadowing",
			"-target:freestanding_amd64_sysv",
			"-build-mode:obj",
			"-no-entry-point",
			"-disable-red-zone",
			// itDEFINE,
		},
	)

	objs := collect_objs(KERNEL_DIR, nil)
	kernelEndPath, _ := filepath.join({"diskimg", "kernel.elf"})
	osErr := os.make_directory_all(filepath.dir(kernelEndPath))
	if osErr != .Exist do ensure_os(osErr)

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "ld.lld", "-pie", "--image-base=0x0", "-o", kernelEndPath, "--entry=kernel_main")
	for o in objs do append(&cmd, o)
	exec(cmd[:])
}


collect_objs :: proc(dir: string, pred: proc(_: string) -> bool) -> [dynamic]string {
	d, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do panic(fmt.tprintf("failed to read %s", dir))
	out := make([dynamic]string, context.temp_allocator)
	for f in d {
		if strings.has_suffix(f.name, ".o") && (pred == nil || pred(f.name)) {
			append(&out, fmt.tprintf("%s/%s", dir, f.name))
		}
	}
	return out
}

ensure_os :: proc(err: os.Error) {
	if err != nil do ensure(false, fmt.tprintf("OS ERROR: %s", os.error_string(err)))
}
asm_build :: proc(src, dstFolder: string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "clang", "-target", "x86_64-unknown-none-elf", "-fPIC")
	when ODIN_DEBUG {
		append(&cmd, "-g")
	}
	dst, _ := filepath.join(
		{dstFolder, fmt.tprintf("%s%s", strings.trim_suffix(filepath.base(src), ".asm"), ".o")},
	)
	append(&cmd, "-c", src, "-o", dst)

	osErr := os.make_directory_all(dstFolder)
	if osErr != .Exist do ensure_os(osErr)
	exec(cmd[:])
}
odin_build :: proc(pkg, outDir, out: string, extra: []string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", pkg)
	when ODIN_DEBUG {
		append(&cmd, "-debug", "-o:minimal")
	} else {
		append(&cmd, "-o:aggressive")
	}
	for e in extra do append(&cmd, e)
	append(&cmd, fmt.tprintf("-out:%s/%s", outDir, out))

	osErr := os.make_directory_all(outDir)
	if osErr != .Exist do ensure_os(osErr)

	exec(cmd[:])
}
exec :: proc(command: []string) {
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{working_dir = ".", command = command},
		allocator = context.temp_allocator,
	)
	// fmt.println(command)
	if err != nil do panic(fmt.tprintf("error executing COMMAND %s : ERROR %s", command, os.error_string(err)))
	msg := fmt.tprintf("%s%s", string(stdout), string(stderr))
	if state.exit_code != 0 do panic(fmt.tprintf("error executing COMMAND %s : ERROR %s", command, msg))
	fmt.print(msg)
}
