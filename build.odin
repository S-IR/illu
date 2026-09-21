package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

BUILD_DIR :: "build-dir"

BUILD_BOOTLOADER :: #config(BUILD_BOOTLOADER, true)
BUILD_KERNEL :: #config(BUILD_KERNEL, true)
BUILD_ADAM :: #config(BUILD_ADAM, true)

BUILD_NTDLL_IMMITATOR :: #config(BUILD_NTDLL_IMMITATOR, true)
BUILD_FIRSTPE :: #config(BUILD_FIRSTPE, ODIN_DEBUG)

main :: proc() {
	os.remove_all(BUILD_DIR)
	os.make_directory_all(BUILD_DIR)

	// when ODIN_DEBUG do run_tests()

	when BUILD_BOOTLOADER do build_bootloader()
	when BUILD_KERNEL do build_kernel()
	when BUILD_NTDLL_IMMITATOR do build_ntdll_immitator()
	when BUILD_FIRSTPE do build_firstpe()
	when BUILD_ADAM do build_adam()
}

run_tests :: proc() {
	exec([]string{"odin", "test", "kernel/pmm", "-debug", "-out:build-dir/pmm-tests"})
	exec(
		[]string {
			"odin",
			"test",
			"kernel",
			"-debug",
			"-define:KERNEL_BUILD=true",
			"-out:build-dir/kernel-tests",
		},
	)
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
