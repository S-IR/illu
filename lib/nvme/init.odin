package nvme

import "../alloc"
import "../clock"
import "../pci"
import "../shared"
import "../syscalls"

#assert(ADMIN_QUEUE_DEPTH * size_of(Command) <= shared.PAGE_SIZE)

init :: proc(pciDevice: ^pci.Device) -> (device: Device, blockCount: u64, err: shared.Error) {
	bar := pciDevice.bars[0]
	if !bar.isMemory || bar.addr == 0 do return {}, 0, .NvmeBarNotMemory

	command := pci.config_read_u16(pciDevice, pci.CONFIG_COMMAND_OFFSET)
	pci.config_write_u16(
		pciDevice,
		pci.CONFIG_COMMAND_OFFSET,
		command | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER,
	)

	regs := Controller{([^]u8)(uintptr(bar.addr))}
	cap := read_cap(regs)
	if cap.to == 0 do return {}, 0, .NvmeCapTimeoutZero
	controller_disable(regs, cap) or_return

	if cap.mpsmin != 0 do return {}, 0, .NvmePageSizeUnsupported
	if cap.cssNcss == 0 && cap.cssIocss == 0 do return {}, 0, .NvmeCommandSetUnsupported
	stride := doorbell_stride(cap)
	if bar.size < u64(regDoorbells + 4 * stride) do return {}, 0, .NvmeBarTooSmall

	pages := alloc.dma_pages(3) or_return
	adminSq := pages
	adminCq := pages + shared.PAGE_SIZE
	ident := pages + 2 * shared.PAGE_SIZE
	defer if err != .None {
		_ = controller_disable(regs, cap)
		assert(syscalls.mem_free_userspace(pages) == .None)
	}

	device.regs = regs
	device.cap = cap
	device.queueDepth = u32(cap.mqes) + 1
	assert(device.queueDepth >= 2)
	device.admin = {
		sq    = ([^]Command)(uintptr(adminSq)),
		cq    = ([^]Completion)(uintptr(adminCq)),
		depth = ADMIN_QUEUE_DEPTH,
		phase = 1,
	}

	cc := CC {
		css    = 0b000 if cap.cssNcss != 0 else 0b110,
		iosqes = 6,
		iocqes = 4,
	}
	write_aqa(regs, AQA{asqs = u16(ADMIN_QUEUE_DEPTH - 1), acqs = u16(ADMIN_QUEUE_DEPTH - 1)})
	write64(regs, regAsq, adminSq)
	write64(regs, regAcq, adminCq)
	write_cc(regs, cc)
	cc.en = 1
	write_cc(regs, cc)
	enableDeadline := ready_deadline(cap)
	for read_csts(regs).rdy == 0 {
		if read_csts(regs).cfs != 0 do return {}, 0, .NvmeControllerFatal
		if clock.expired(enableDeadline) do return {}, 0, .NvmeEnableTimeout
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
	if idCtrl.sqes & 0xF != 6 || idCtrl.cqes & 0xF != 4 do return {}, 0, .NvmeEntrySizeUnsupported
	if idCtrl.nn == 0 do return {}, 0, .NvmeNoNamespace
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
	if device.nsid == 0 do return {}, 0, .NvmeNoNamespace

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
	if lbaFmtIdx > idNs.nlbaf do return {}, 0, .NvmeLbaFormatInvalid
	if idNs.lbaf[lbaFmtIdx].lbads < 9 || idNs.lbaf[lbaFmtIdx].lbads > 12 do return {}, 0, .NvmeBlockSizeUnsupported
	device.lbaSize = u32(1) << idNs.lbaf[lbaFmtIdx].lbads
	nlbLimit := (u64(max(u16)) + 1) * u64(device.lbaSize)
	if device.maxTransfer == 0 || device.maxTransfer > nlbLimit do device.maxTransfer = nlbLimit

	if idNs.nsze == 0 do return {}, 0, .NvmeNamespaceEmpty
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
	if device.queueCount == 0 do return {}, 0, .NvmeNoIoQueues
	device.nextQid = 1
	return device, blockCount, .None
}

controller_disable :: proc(regs: Controller, cap: CAP) -> shared.Error {
	cc := read_cc(regs)
	if cc.en != 0 {
		cc.en = 0
		write_cc(regs, cc)
	}
	deadline := ready_deadline(cap)
	for read_csts(regs).rdy != 0 {
		if clock.expired(deadline) do return .NvmeDisableTimeout
	}
	return .NvmeControllerFatal if read_csts(regs).cfs != 0 else .None
}

queue_pair_create :: proc(device: ^Device, msixRow: u16) -> (info: QueueInfo, err: shared.Error) {
	assert(device.nextQid >= 1)
	assert(device.queueDepth >= 2 && device.queueDepth <= QUEUE_DEPTH_SPEC_MAX)
	if device.nextQid > device.queueCount do return {}, .NvmeIoQueuesExhausted
	assert(device.nextQid <= u32(max(u16)))
	qid := u16(device.nextQid)

	sqPages :=
		(u64(device.queueDepth) * size_of(Command) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE
	cqPages :=
		(u64(device.queueDepth) * size_of(Completion) + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE
	pages := alloc.dma_pages(sqPages + cqPages) or_return
	defer if err != .None do assert(syscalls.mem_free_userspace(pages) == .None)
	sq := pages
	cq := pages + sqPages * shared.PAGE_SIZE
	sizeMinus1 := u16(device.queueDepth - 1)

	_ = admin_execute_command(
		device,
		{
			header = {opcode = u8(ADMIN_COMMANDS.CREATE_IO_CQ)},
			dataAddr = cq,
			args = {
				createCq = {
					queueId = qid,
					sizeMinus1 = sizeMinus1,
					flags = {.Contiguous, .InterruptsEnable},
					interruptVector = msixRow,
				},
			},
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
		.None
}
