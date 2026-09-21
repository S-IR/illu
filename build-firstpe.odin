package build

import "core:os"
import "core:path/filepath"

build_firstpe :: proc() {
	dir, _ := filepath.join({BUILD_DIR, "firstpe"})
	os.make_directory_all(dir)

	syscallObjOut, _ := filepath.join({dir, "syscalls.obj"})
	exec(
		[]string {
			"clang",
			"-target",
			"x86_64-pc-windows-gnu",
			"-c",
			"lib/syscalls/syscalls.asm",
			"-o",
			syscallObjOut,
		},
	)

	helpersObjOut, _ := filepath.join({dir, "firstpe_helpers.obj"})
	exec(
		[]string {
			"clang",
			"-target",
			"x86_64-pc-windows-gnu",
			"-c",
			"asm_helpers/firstpe_helpers.asm",
			"-o",
			helpersObjOut,
		},
	)

	objOut, _ := filepath.join({dir, "firstpe.o"})
	odin_build(
		"firstpe",
		objOut,
		{
			"-vet-shadowing",
			"-target:freestanding_amd64_win64",
			"-build-mode:obj",
			"-no-entry-point",
			"-disable-red-zone",
		},
	)

	objs := collect_objs(dir)
	out :: "firstpe" + filepath.SEPARATOR_STRING + "firstpe.exe"
	ntdllLib :: "diskimg" + filepath.SEPARATOR_STRING + "ntdll.lib"

	linkCmd := make([dynamic]string, context.temp_allocator)
	append(
		&linkCmd,
		"lld-link",
		"-subsystem:console",
		"-entry:_start",
		"-libpath:diskimg",
		ntdllLib,
		"-out:" + out,
	)
	for o in objs do append(&linkCmd, o)
	exec(linkCmd[:])
}
