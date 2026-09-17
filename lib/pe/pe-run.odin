package pe
import "../shared"
import "../syscalls"
import "core:mem"
PeLoadError :: enum {
	None,
	InvalidImage,
	MemoryAllocFailed,
	ProtDomainFailed,
	ExecutionFailed,
	CopyFailed,
}
PE_STACK_SIZE :: u64(16 * mem.Kilobyte)

run :: proc(image: ^Image, data: []u8, arg0, arg1: u64) -> PeLoadError {
	if image.regions == nil || len(image.regions) == 0 do return .InvalidImage

	imageBytes, ok := align_up(u64(image.sizeOfImage), shared.PAGE_SIZE)
	if !ok do return .InvalidImage
	imagePages := imageBytes / shared.PAGE_SIZE

	stackPages := PE_STACK_SIZE / shared.PAGE_SIZE
	mmapRegions := [3]syscalls.MMapRegion {
		{pageSize = ._4KB, count = imagePages, flags = {.Write, .NX}},
		{pageSize = ._4KB, count = 1, flags = {}},
		{pageSize = ._4KB, count = stackPages, flags = {.Write, .NX}},
	}

	mmapErr, base := syscalls.syscall_mmap_userspace(mmapRegions[:])
	if mmapErr != .None || base == nil do return .MemoryAllocFailed

	baseAddr := uintptr(base)
	actualBase := u64(baseAddr)
	delta := actualBase - image.imageBase

	guardAddr := actualBase + imageBytes
	stackAddr := guardAddr + shared.PAGE_SIZE

	defer {
		_ = syscalls.syscall_mfree_userspace([]u64{actualBase, guardAddr, stackAddr})
	}


	for region in image.regions {
		section := image.sections[region.sectionIndex]
		sectionOffset := align_down(u64(section.virtualAddress), shared.PAGE_SIZE)
		if section.rawSize > 0 {
			if !has_range(data, u64(section.rawOffset), u64(section.rawSize)) do return .CopyFailed
			dst := rawptr(baseAddr + uintptr(sectionOffset))
			mem.copy(dst, &data[section.rawOffset], int(section.rawSize))
		}
	}
	apply_relocations(image, base, delta)

	memRegions := make(
		[]syscalls.MemRegion,
		len(image.regions) + 2,
		allocator = context.temp_allocator,
	)
	for region, i in image.regions {
		section := image.sections[region.sectionIndex]
		sectionOffset := align_down(u64(section.virtualAddress), shared.PAGE_SIZE)
		addr := actualBase + sectionOffset
		memRegions[i] = {
			phys     = addr,
			logical  = addr,
			size     = region.regionData.size,
			pageSize = ._4KB,
			flags    = region.regionData.flags,
		}
	}
	guardIdx := len(image.regions)
	memRegions[guardIdx] = {
		phys     = guardAddr,
		logical  = guardAddr,
		size     = shared.PAGE_SIZE,
		pageSize = ._4KB,
		flags    = {},
	}
	stackIdx := guardIdx + 1
	memRegions[stackIdx] = {
		phys     = stackAddr,
		logical  = stackAddr,
		size     = PE_STACK_SIZE,
		pageSize = ._4KB,
		flags    = {.User, .Write, .NX},
	}

	createErr, handle := syscalls.syscall_prot_domain_create_userspace(memRegions)
	if createErr != .None do return .ProtDomainFailed


	stackTop := stackAddr + PE_STACK_SIZE - 8
	entryLogical := actualBase + u64(image.entryRva)
	execErr := syscalls.syscall_execution_start_userspace(
		handle,
		entryLogical,
		stackTop,
		arg0,
		arg1,
	)
	if execErr != .None do return .ExecutionFailed

	return .None
}
apply_relocations :: proc "contextless" (image: ^Image, base: rawptr, delta: u64) {
	if delta == 0 do return
	baseAddr := uintptr(base)
	for rva in image.relocations {
		ptr := (^u64)(rawptr(baseAddr + uintptr(rva)))
		ptr^ += delta
	}
}
