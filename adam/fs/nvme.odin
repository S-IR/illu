package fs


import "../../lib/clock"
import "../../lib/nvme"
import "../../lib/pci"
import "../../lib/shared"
import "../../lib/syscalls"
import "core:mem"

NvmeError :: enum u8 {
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
	AdminTimeout,
	AdminFailed,
	EntrySizeUnsupported,
	NoNamespace,
	LbaFormatInvalid,
	BlockSizeUnsupported,
	NamespaceEmpty,
	NoIoQueues,
	IoQueuesExhausted,
	SelftestMismatch,
	CouldNotAppendDevice,
}

Error :: union #shared_nil {
	NvmeError,
	nvme.IoError,
}

QUEUE_DEPTH_MAX :: u32(64)
#assert(QUEUE_DEPTH_MAX * size_of(nvme.Command) <= shared.PAGE_SIZE)


Nvme :: struct {
	regs:       Controller,
	cap:        CAP,
	admin:      AdminQueue,
	nsid:       u32,
	lbaSize:    u32,
	queueDepth: u32,
	queueCount: u32,
	nextQid:    u32,
	serial:     [20]u8,
	model:      [40]u8,
}

nvme_init :: proc(device: ^pci.Device) -> (err: Error) {
	bar := device.bars[0]
	if !bar.isMemory || bar.addr == 0 do return .BarNotMemory

	command := pci.config_read_u16(device, pci.CONFIG_COMMAND_OFFSET)
	pci.config_write_u16(
		device,
		pci.CONFIG_COMMAND_OFFSET,
		command | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER,
	)

	regs := Controller{([^]u8)(uintptr(bar.addr))}
	cap := read_cap(regs)
	if cap.to == 0 do return .CapTimeoutZero
	nvme_disable(regs, cap) or_return

	if cap.mpsmin != 0 do return .PageSizeUnsupported
	if cap.cssNcss == 0 && cap.cssIocss == 0 do return .CommandSetUnsupported
	stride := doorbell_stride(cap)
	if bar.size < u64(regDoorbells + 4 * stride) do return .BarTooSmall

	pages := dma_pages(3) or_return
	adminSq := pages
	adminCq := pages + shared.PAGE_SIZE
	ident := pages + 2 * shared.PAGE_SIZE

	n := new(Nvme)
	defer if err != nil {
		_ = nvme_disable(regs, cap)
		free(n)
		assert(syscalls.mem_free_userspace(pages) == .None)
	}

	n.regs = regs
	n.cap = cap
	n.queueDepth = min(QUEUE_DEPTH_MAX, u32(cap.mqes) + 1)
	assert(n.queueDepth >= 2)
	n.admin = {
		sq    = ([^]nvme.Command)(uintptr(adminSq)),
		cq    = ([^]nvme.Completion)(uintptr(adminCq)),
		depth = n.queueDepth,
		phase = 1,
	}

	cc := CC {
		css    = 0b000 if cap.cssNcss != 0 else 0b110,
		iosqes = 6,
		iocqes = 4,
	}
	write_aqa(regs, AQA{asqs = u16(n.queueDepth - 1), acqs = u16(n.queueDepth - 1)})
	write64(regs, regAsq, adminSq)
	write64(regs, regAcq, adminCq)
	write_cc(regs, cc)
	cc.en = 1
	write_cc(regs, cc)
	enableDeadline := ready_deadline(cap)
	for read_csts(regs).rdy == 0 {
		if read_csts(regs).cfs != 0 do return .ControllerFatal
		if clock.expired(enableDeadline) do return .EnableTimeout
	}

	_ = admin_run(
		n,
		{
			header = {opcode = u8(ADMIN_COMMANDS.IDENTIFY)},
			dataAddr = ident,
			args = {identify = {what = u8(IDENTIFY_CNS.CONTROLLER)}},
		},
	) or_return
	idCtrl := (^IdentifyController)(uintptr(ident))
	if idCtrl.sqes & 0xF != 6 || idCtrl.cqes & 0xF != 4 do return .EntrySizeUnsupported
	if idCtrl.nn == 0 do return .NoNamespace
	n.serial = idCtrl.sn
	n.model = idCtrl.mn

	_ = admin_run(
		n,
		{
			header = {opcode = u8(ADMIN_COMMANDS.IDENTIFY)},
			dataAddr = ident,
			args = {identify = {what = u8(IDENTIFY_CNS.ACTIVE_NS_LIST)}},
		},
	) or_return
	n.nsid = (^ActiveNamespaceList)(uintptr(ident)).nsid[0]
	if n.nsid == 0 do return .NoNamespace

	_ = admin_run(
		n,
		{
			header = {opcode = u8(ADMIN_COMMANDS.IDENTIFY)},
			namespaceId = n.nsid,
			dataAddr = ident,
			args = {identify = {what = u8(IDENTIFY_CNS.NAMESPACE)}},
		},
	) or_return
	idNs := (^IdentifyNamespace)(uintptr(ident))
	lbaFmtIdx := idNs.flbas & 0xF
	if lbaFmtIdx > idNs.nlbaf do return .LbaFormatInvalid
	if idNs.lbaf[lbaFmtIdx].lbads < 9 || idNs.lbaf[lbaFmtIdx].lbads > 12 do return .BlockSizeUnsupported
	n.lbaSize = u32(1) << idNs.lbaf[lbaFmtIdx].lbads
	if idNs.nsze == 0 do return .NamespaceEmpty
	blockCount := idNs.nsze

	granted := admin_run(
		n,
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
	n.queueCount = min(byDevice, byBar)
	if n.queueCount == 0 do return .NoIoQueues
	n.nextQid = 1

	syscalls.syscall_debug_print_userspace("nvme: io queue pairs", u64(n.queueCount))
	syscalls.syscall_debug_print_userspace("nvme: blocks", blockCount)

	when ODIN_DEBUG {
		nvme_selftest(n) or_return
		syscalls.syscall_debug_print_userspace("nvme: selftest ok", 0)
	}

	if !disk_add(n, n.lbaSize, blockCount) do return .CouldNotAppendDevice
	return nil
}


dma_pages :: proc(count: u64) -> (base: u64, err: NvmeError) {
	assert(count > 0)
	regions := [1]syscalls.MMapRegion{{pageSize = ._4KB, count = count, flags = {.Write, .NX}}}
	mmapErr, addr := syscalls.syscall_mmap_userspace(regions[:])
	if mmapErr != .None do return 0, .OutOfMemory
	assert(addr != nil)
	assert(u64(uintptr(addr)) % shared.PAGE_SIZE == 0)
	mem.zero(addr, int(count * shared.PAGE_SIZE))
	return u64(uintptr(addr)), .None
}

nvme_disable :: proc(regs: Controller, cap: CAP) -> NvmeError {
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


nvme_queue_pair_create :: proc(n: ^Nvme) -> (info: nvme.QueueInfo, err: NvmeError) {
	assert(n.nextQid >= 1)
	assert(n.queueDepth >= 2 && n.queueDepth <= QUEUE_DEPTH_MAX)
	if n.nextQid > n.queueCount do return {}, .IoQueuesExhausted
	assert(n.nextQid <= u32(max(u16)))
	qid := u16(n.nextQid)

	pages := dma_pages(2) or_return
	defer if err != .None do assert(syscalls.mem_free_userspace(pages) == .None)
	sq := pages
	cq := pages + shared.PAGE_SIZE
	sizeMinus1 := u16(n.queueDepth - 1)

	_ = admin_run(
		n,
		{
			header = {opcode = u8(ADMIN_COMMANDS.CREATE_IO_CQ)},
			dataAddr = cq,
			args = {createCq = {queueId = qid, sizeMinus1 = sizeMinus1, flags = {.Contiguous}}},
		},
	) or_return
	_, sqErr := admin_run(
		n,
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
		_, deleteErr := admin_run(
			n,
			{
				header = {opcode = u8(ADMIN_COMMANDS.DELETE_IO_CQ)},
				args = {deleteQueue = {queueId = qid}},
			},
		)
		assert(deleteErr == .None)
		return {}, sqErr
	}

	n.nextQid += 1
	return {
			sq = ([^]nvme.Command)(uintptr(sq)),
			cq = ([^]nvme.Completion)(uintptr(cq)),
			sqDoorbell = doorbell(n.regs, n.cap, qid, false),
			cqDoorbell = doorbell(n.regs, n.cap, qid, true),
			depth = n.queueDepth,
			qid = qid,
			nsid = n.nsid,
			lbaSize = n.lbaSize,
		},
		.None
}


SELFTEST_BLOCK :: u64(0)
nvme_selftest :: proc(n: ^Nvme) -> Error {
	info := nvme_queue_pair_create(n) or_return
	q := nvme.queue_init(info)

	page := dma_pages(1) or_return
	defer assert(syscalls.mem_free_userspace(page) == .None)
	block := ([^]u8)(uintptr(page))[:n.lbaSize]

	for &b, i in block do b = u8(i * 7 + 1)
	nvme.queue_io_sync(&q, .Write, SELFTEST_BLOCK, block) or_return
	mem.zero_slice(block)
	nvme.queue_io_sync(&q, .Read, SELFTEST_BLOCK, block) or_return
	for b, i in block do if b != u8(i * 7 + 1) do return .SelftestMismatch
	return nil
}
