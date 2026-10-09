package nvme

import "../clock"
import "../pci"
import "../shared"
import "../syscalls"
import "core:mem"

#assert(QUEUE_DEPTH_MAX * size_of(Command) <= shared.PAGE_SIZE)

ControllerError :: enum u8 {
	None,
	BarNotMemory,
	BarTooSmall,
	CapTimeoutZero,
	PageSizeUnsupported,
	CommandSetUnsupported,
	DisableTimeout,
	EnableTimeout,
	ControllerFatal,
	OutOfMemory,
	EntrySizeUnsupported,
	NoNamespace,
	LbaFormatInvalid,
	BlockSizeUnsupported,
	NamespaceEmpty,
	NoIoQueues,
	IoQueuesExhausted,
	SelftestMismatch,
}

InitError :: union #shared_nil {
	ControllerError,
	Error,
}

init :: proc(pciDevice: ^pci.Device) -> (device: Device, blockCount: u64, err: InitError) {
	bar := pciDevice.bars[0]
	if !bar.isMemory || bar.addr == 0 do return {}, 0, .BarNotMemory

	command := pci.config_read_u16(pciDevice, pci.CONFIG_COMMAND_OFFSET)
	pci.config_write_u16(
		pciDevice,
		pci.CONFIG_COMMAND_OFFSET,
		command | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER,
	)

	regs := Controller{([^]u8)(uintptr(bar.addr))}
	cap := read_cap(regs)
	if cap.to == 0 do return {}, 0, .CapTimeoutZero
	controller_disable(regs, cap) or_return

	if cap.mpsmin != 0 do return {}, 0, .PageSizeUnsupported
	if cap.cssNcss == 0 && cap.cssIocss == 0 do return {}, 0, .CommandSetUnsupported
	stride := doorbell_stride(cap)
	if bar.size < u64(regDoorbells + 4 * stride) do return {}, 0, .BarTooSmall

	pages := dma_pages(3) or_return
	adminSq := pages
	adminCq := pages + shared.PAGE_SIZE
	ident := pages + 2 * shared.PAGE_SIZE
	defer if err != nil {
		_ = controller_disable(regs, cap)
		assert(syscalls.mem_free_userspace(pages) == .None)
	}

	device.regs = regs
	device.cap = cap
	device.queueDepth = min(QUEUE_DEPTH_MAX, u32(cap.mqes) + 1)
	assert(device.queueDepth >= 2)
	device.admin = {
		sq    = ([^]Command)(uintptr(adminSq)),
		cq    = ([^]Completion)(uintptr(adminCq)),
		depth = device.queueDepth,
		phase = 1,
	}

	cc := CC {
		css    = 0b000 if cap.cssNcss != 0 else 0b110,
		iosqes = 6,
		iocqes = 4,
	}
	write_aqa(regs, AQA{asqs = u16(device.queueDepth - 1), acqs = u16(device.queueDepth - 1)})
	write64(regs, regAsq, adminSq)
	write64(regs, regAcq, adminCq)
	write_cc(regs, cc)
	cc.en = 1
	write_cc(regs, cc)
	enableDeadline := ready_deadline(cap)
	for read_csts(regs).rdy == 0 {
		if read_csts(regs).cfs != 0 do return {}, 0, .ControllerFatal
		if clock.expired(enableDeadline) do return {}, 0, .EnableTimeout
	}

	_ = admin_execute_command(
		&device,
		{
			header = {opcode = u8(ADMIN_COMMANDS.IDENTIFY)},
			dataAddr = ident,
			args = {identify = {what = u8(IDENTIFY_CNS.CONTROLLER)}},
		},
	) or_return
	idCtrl := (^IdentifyController)(uintptr(ident))
	if idCtrl.sqes & 0xF != 6 || idCtrl.cqes & 0xF != 4 do return {}, 0, .EntrySizeUnsupported
	if idCtrl.nn == 0 do return {}, 0, .NoNamespace
	device.serial = idCtrl.sn
	device.model = idCtrl.mn

	if idCtrl.mdts != 0 && idCtrl.mdts < 52 do device.maxTransfer = (u64(1) << idCtrl.mdts) * shared.PAGE_SIZE

	_ = admin_execute_command(
		&device,
		{
			header = {opcode = u8(ADMIN_COMMANDS.IDENTIFY)},
			dataAddr = ident,
			args = {identify = {what = u8(IDENTIFY_CNS.ACTIVE_NS_LIST)}},
		},
	) or_return
	device.nsid = (^ActiveNamespaceList)(uintptr(ident)).nsid[0]
	if device.nsid == 0 do return {}, 0, .NoNamespace

	_ = admin_execute_command(
		&device,
		{
			header = {opcode = u8(ADMIN_COMMANDS.IDENTIFY)},
			namespaceId = device.nsid,
			dataAddr = ident,
			args = {identify = {what = u8(IDENTIFY_CNS.NAMESPACE)}},
		},
	) or_return
	idNs := (^IdentifyNamespace)(uintptr(ident))
	lbaFmtIdx := idNs.flbas & 0xF
	if lbaFmtIdx > idNs.nlbaf do return {}, 0, .LbaFormatInvalid
	if idNs.lbaf[lbaFmtIdx].lbads < 9 || idNs.lbaf[lbaFmtIdx].lbads > 12 do return {}, 0, .BlockSizeUnsupported
	device.lbaSize = u32(1) << idNs.lbaf[lbaFmtIdx].lbads
	nlbLimit := (u64(max(u16)) + 1) * u64(device.lbaSize)
	if device.maxTransfer == 0 || device.maxTransfer > nlbLimit do device.maxTransfer = nlbLimit

	if idNs.nsze == 0 do return {}, 0, .NamespaceEmpty
	blockCount = idNs.nsze

	granted := admin_execute_command(
		&device,
		{
			header = {opcode = u8(ADMIN_COMMANDS.SET_FEATURES)},
			args = {
				setFeatures = {
					feature = SET_FEATURES_FID_NUM_QUEUES,
					value = (NUM_QUEUES_REQUEST_MAX - 1) | (NUM_QUEUES_REQUEST_MAX - 1) << 16,
				},
			},
		},
	) or_return
	byDevice := min(granted & 0xFFFF, granted >> 16) + 1
	byBar := u32((bar.size - u64(regDoorbells)) / u64(2 * stride)) - 1
	device.queueCount = min(byDevice, byBar)
	if device.queueCount == 0 do return {}, 0, .NoIoQueues
	device.nextQid = 1

	when ODIN_DEBUG {
		selftest(&device) or_return
	}
	return device, blockCount, nil
}

dma_pages :: proc(count: u64) -> (base: u64, err: ControllerError) {
	assert(count > 0)
	regions := [1]syscalls.MMapRegion{{pageSize = ._4KB, count = count, flags = {.Write, .NX}}}
	mmapErr, addr := syscalls.syscall_mmap_userspace(regions[:])
	if mmapErr != .None do return 0, .OutOfMemory
	assert(addr != nil)
	assert(u64(uintptr(addr)) % shared.PAGE_SIZE == 0)
	mem.zero(addr, int(count * shared.PAGE_SIZE))
	return u64(uintptr(addr)), .None
}

controller_disable :: proc(regs: Controller, cap: CAP) -> ControllerError {
	cc := read_cc(regs)
	if cc.en != 0 {
		cc.en = 0
		write_cc(regs, cc)
	}
	deadline := ready_deadline(cap)
	for read_csts(regs).rdy != 0 {
		if clock.expired(deadline) do return .DisableTimeout
	}
	return .ControllerFatal if read_csts(regs).cfs != 0 else .None
}

queue_pair_create :: proc(device: ^Device) -> (info: QueueInfo, err: InitError) {
	assert(device.nextQid >= 1)
	assert(device.queueDepth >= 2 && device.queueDepth <= QUEUE_DEPTH_MAX)
	if device.nextQid > device.queueCount do return {}, .IoQueuesExhausted
	assert(device.nextQid <= u32(max(u16)))
	qid := u16(device.nextQid)

	pages := dma_pages(2) or_return
	defer if err != nil do assert(syscalls.mem_free_userspace(pages) == .None)
	sq := pages
	cq := pages + shared.PAGE_SIZE
	sizeMinus1 := u16(device.queueDepth - 1)

	_ = admin_execute_command(
		device,
		{
			header = {opcode = u8(ADMIN_COMMANDS.CREATE_IO_CQ)},
			dataAddr = cq,
			args = {createCq = {queueId = qid, sizeMinus1 = sizeMinus1, flags = {.Contiguous}}},
		},
	) or_return
	_, sqErr := admin_execute_command(
		device,
		{
			header = {opcode = u8(ADMIN_COMMANDS.CREATE_IO_SQ)},
			dataAddr = sq,
			args = {
				createSq = {
					queueId = qid,
					sizeMinus1 = sizeMinus1,
					flags = {.Contiguous},
					completionQueueId = qid,
				},
			},
		},
	)
	if sqErr != .None {
		_, deleteErr := admin_execute_command(
			device,
			{
				header = {opcode = u8(ADMIN_COMMANDS.DELETE_IO_CQ)},
				args = {deleteQueue = {queueId = qid}},
			},
		)
		assert(deleteErr == .None)
		return {}, sqErr
	}

	device.nextQid += 1
	return {
			sq = ([^]Command)(uintptr(sq)),
			cq = ([^]Completion)(uintptr(cq)),
			sqDoorbell = doorbell(device.regs, device.cap, qid, false),
			cqDoorbell = doorbell(device.regs, device.cap, qid, true),
			depth = device.queueDepth,
			qid = qid,
			nsid = device.nsid,
			lbaSize = device.lbaSize,
			maxTransfer = device.maxTransfer,
		},
		nil
}

SELFTEST_BLOCK :: u64(0)
selftest :: proc(device: ^Device) -> InitError {
	info := queue_pair_create(device) or_return
	q := queue_init(info)

	page := dma_pages(1) or_return
	defer assert(syscalls.mem_free_userspace(page) == .None)
	block := ([^]u8)(uintptr(page))[:device.lbaSize]

	for &b, i in block do b = u8(i * 7 + 1)
	bufs := [1][]u8{block}
	pending := queue_io(&q, .Write, SELFTEST_BLOCK, bufs[:], nil) or_return
	wait(pending) or_return
	mem.zero_slice(block)
	pending = queue_io(&q, .Read, SELFTEST_BLOCK, bufs[:], nil) or_return
	wait(pending) or_return
	for b, i in block do if b != u8(i * 7 + 1) do return .SelftestMismatch
	return nil
}
