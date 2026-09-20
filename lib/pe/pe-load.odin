package pe
import "../shared"
import "../syscalls"
import "core:mem"

PE_STACK_SIZE :: u64(16 * mem.Kilobyte)

pe_load_into_memory :: proc(image: ^PeImage, sections: []PeSection, data: []u8) -> (actualBase: u64, ok: bool) {
	imageBytes, alignOk := align_up(u64(image.sizeOfImage), shared.PAGE_SIZE)
	if !alignOk do return 0, false
	imagePages := imageBytes / shared.PAGE_SIZE

	mmapRegions := [1]syscalls.MMapRegion {
		{pageSize = ._4KB, count = imagePages, flags = {.Write, .NX}},
	}
	mmapErr, base := syscalls.syscall_mmap_userspace(mmapRegions[:])
	if mmapErr != .None || base == nil do return 0, false
	defer if !ok do syscalls.syscall_mfree_userspace([]u64{actualBase})

	actualBase = u64(uintptr(base))
	delta := actualBase - image.imageBase

	for &region in image.regions {
		region.logical += delta
		region.phys = region.logical
	}

	for section in sections {
		if section.rawSize == 0 do continue
		if !has_range(data, u64(section.rawOffset), u64(section.rawSize)) do return 0, false
		sectionOffset := align_down(u64(section.virtualAddress), shared.PAGE_SIZE)
		dst := rawptr(uintptr(actualBase) + uintptr(sectionOffset))
		mem.copy(dst, &data[section.rawOffset], int(section.rawSize))
	}
	apply_relocations(image, base, delta)

	return actualBase, true
}

apply_relocations :: proc "contextless" (image: ^PeImage, base: rawptr, delta: u64) {
	if delta == 0 do return
	baseAddr := uintptr(base)
	for rva in image.relocations {
		ptr := (^u64)(rawptr(baseAddr + uintptr(rva)))
		ptr^ += delta
	}
}

PeRunError :: enum {
	None,
	NoEntryPoint,
	DomainCreateFailed,
	StackAllocFailed,
	StackGrantFailed,
	ImportNotFound,
	ImportGrantFailed,
	ExportNotFound,
	ExecutionStartFailed,
}

pe_run :: proc(bc: ^Bytecode, entryRva: u32, arg0, arg1: u64) -> PeRunError {
	if entryRva == 0 do return .NoEntryPoint

	createErr, handle := syscalls.syscall_prot_domain_create_userspace(bc.image.regions[:])
	if createErr != .None do return .DomainCreateFailed

	stackPages := PE_STACK_SIZE / shared.PAGE_SIZE
	stackMmap := [2]syscalls.MMapRegion {
		{pageSize = ._4KB, count = 1, flags = {}},
		{pageSize = ._4KB, count = stackPages, flags = {.Write, .NX}},
	}
	stackMmapErr, stackBase := syscalls.syscall_mmap_userspace(stackMmap[:])
	if stackMmapErr != .None || stackBase == nil do return .StackAllocFailed

	guardAddr := u64(uintptr(stackBase))
	stackAddr := guardAddr + shared.PAGE_SIZE
	stackRegions := [2]syscalls.MemRegion {
		{phys = guardAddr, logical = guardAddr, size = shared.PAGE_SIZE, pageSize = ._4KB, flags = {}},
		{
			phys = stackAddr,
			logical = stackAddr,
			size = PE_STACK_SIZE,
			pageSize = ._4KB,
			flags = {.User, .Write, .NX},
		},
	}
	stackEditErr := syscalls.syscall_prot_domain_edit_userspace(handle, stackRegions[:], .Add)
	if stackEditErr != .None do return .StackGrantFailed

	for imp in bc.image.imports {
		dep, found := get(imp.dll)
		if !found do return .ImportNotFound

		editErr := syscalls.syscall_prot_domain_edit_userspace(handle, dep.image.regions[:], .Add)
		if editErr != .None do return .ImportGrantFailed

		for entry in imp.entries {
			rva, exportFound := dep.image.exports[entry.nameHash]
			if !exportFound do return .ExportNotFound
			slot := (^u64)(rawptr(uintptr(bc.base) + uintptr(entry.thunkRva)))
			slot^ = dep.base + u64(rva)
		}
	}

	stackTop := stackAddr + PE_STACK_SIZE - 8
	entryAddr := bc.base + u64(entryRva)
	execErr := syscalls.syscall_execution_start_userspace(
		handle,
		entryAddr,
		stackTop,
		arg0,
		arg1,
	)
	if execErr != .None do return .ExecutionStartFailed
	return .None
}
