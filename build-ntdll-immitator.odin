package build

import "core:fmt"
import "core:os"
import "core:path/filepath"

build_ntdll_immitator :: proc() {
	os.make_directory_all("diskimg")

	dir, _ := filepath.join({BUILD_DIR, "ntdll_immitator"})
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

	objOut, _ := filepath.join({dir, "ntdll_immitator.o"})
	odin_build(
		"lib/winmitator/ntdll_immitator",
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
	out :: "diskimg" + filepath.SEPARATOR_STRING + "ntdll_immitator.dll"

	linkCmd := make([dynamic]string, context.temp_allocator)
	append(
		&linkCmd,
		"lld-link",
		"-dll",
		"-noentry",
		"-def:lib/winmitator/ntdll_immitator/exports.def",
		"-out:" + out,
	)
	for o in objs do append(&linkCmd, o)
	exec(linkCmd[:])

	aliasThrowaway, _ := filepath.join({dir, "ntdll_alias_throwaway.dll"})
	aliasLib :: "diskimg" + filepath.SEPARATOR_STRING + "ntdll.lib"
	exec(
		[]string {
			"lld-link",
			"-dll",
			"-noentry",
			"-def:lib/winmitator/ntdll_immitator/ntdll_alias.def",
			fmt.tprintf("-out:%s", aliasThrowaway),
			"-implib:" + aliasLib,
		},
	)
}
