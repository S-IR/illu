package build

import "core:os"
import "core:path/filepath"

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
