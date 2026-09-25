package pe
import "../shared"
import "../syscalls"
import "core:mem"

PE_STACK_SIZE :: u64(16 * mem.Kilobyte)

pe_load_into_memory :: proc(
	image: ^PeImage,
	sections: []PeSection,
	data: []u8,
) -> (
	actualBase: u64,
	ok: bool,
) {
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
}

pe_run :: proc(bc: ^Bytecode, entryRva: u32, arg0, arg1: u64) -> PeRunError {
	if entryRva == 0 do return .NoEntryPoint

	authorityPtr: rawptr
	for region in bc.image.regions {
		if .Write in region.flags {
			authorityPtr = rawptr(uintptr(region.logical))
			break
		}
	}
	if authorityPtr == nil do return .DomainCreateFailed

	createErr, handle := syscalls.syscall_prot_domain_create_userspace(
		authorityPtr,
		bc.image.regions[:],
	)
	if createErr != .None do return .DomainCreateFailed


	stackPages := PE_STACK_SIZE / shared.PAGE_SIZE
	mmapRegions := [3]syscalls.MMapRegion {
		{pageSize = ._4KB, count = 1, flags = {}},
		{pageSize = ._4KB, count = stackPages, flags = {.Write, .NX}},
		{pageSize = ._4KB, count = 1, flags = {.Write, .NX}},
	}
	mmapErr, base := syscalls.syscall_mmap_userspace(mmapRegions[:])
	if mmapErr != .None || base == nil do return .StackAllocFailed

	guardAddr := u64(uintptr(base))
	stackAddr := guardAddr + syscalls.descriptor_offset(mmapRegions[:], 1)
	tebLogical := guardAddr + syscalls.descriptor_offset(mmapRegions[:], 2)
	pebLogical := tebLogical + shared.PAGE_SIZE / 2

	(^u64)(rawptr(uintptr(tebLogical + 0x30)))^ = tebLogical
	(^u64)(rawptr(uintptr(tebLogical + 0x60)))^ = pebLogical
	(^u64)(rawptr(uintptr(pebLogical + 0x10)))^ = bc.base

	memRegions := [3]syscalls.MemRegion {
		{
			phys = guardAddr,
			logical = guardAddr,
			size = shared.PAGE_SIZE,
			pageSize = ._4KB,
			flags = {},
		},
		{
			phys = stackAddr,
			logical = stackAddr,
			size = PE_STACK_SIZE,
			pageSize = ._4KB,
			flags = {.User, .Write, .NX},
		},
		{
			phys = tebLogical,
			logical = tebLogical,
			size = shared.PAGE_SIZE,
			pageSize = ._4KB,
			flags = {.User, .Write, .NX},
		},
	}
	editErr := syscalls.syscall_prot_domain_edit_userspace(handle, memRegions[:], .Add)
	if editErr != .None do return .StackGrantFailed

	for imp in bc.image.imports {
		dep, found := get(imp.dll)
		if !found do return .ImportNotFound


		grantRegions := make(
			[dynamic]syscalls.MemRegion,
			0,
			len(dep.image.regions),
			context.temp_allocator,
		)
		privateRegions := make(
			[dynamic]syscalls.MMapRegion,
			0,
			len(dep.image.regions),
			context.temp_allocator,
		)

		for region in dep.image.regions {
			if .Write not_in region.flags {
				append(&grantRegions, region)
				continue
			}
			append(
				&privateRegions,
				syscalls.MMapRegion {
					pageSize = region.pageSize,
					count = region.size / shared.PAGE_SIZE,
					flags = region.flags,
				},
			)
		}

		if len(privateRegions) > 0 {
			privErr, privBase := syscalls.syscall_mmap_userspace(privateRegions[:])
			if privErr != .None || privBase == nil do return .ImportGrantFailed

			idx := 0
			for region in dep.image.regions {
				if .Write not_in region.flags do continue
				offset := syscalls.descriptor_offset(privateRegions[:], idx)
				dst := rawptr(uintptr(privBase) + uintptr(offset))
				mem.copy(dst, rawptr(uintptr(region.logical)), int(region.size))

				grantRegion := region
				grantRegion.phys = u64(uintptr(dst))
				append(&grantRegions, grantRegion)
				idx += 1
			}
		}
		importEditErr := syscalls.syscall_prot_domain_edit_userspace(handle, grantRegions[:], .Add)
		if importEditErr != .None do return .ImportGrantFailed


		for entry in imp.entries {
			rva, exportFound := dep.image.exports[entry.nameHash]
			if !exportFound do return .ExportNotFound
			slot := (^u64)(rawptr(uintptr(bc.base) + uintptr(entry.thunkRva)))
			slot^ = dep.base + u64(rva)
		}
	}
	return .None
}
