package fs


import "../../lib/clock"
import "../../lib/nvme"
import "../../lib/pci"
import "../../lib/shared"
import "../../lib/syscalls"
import "core:mem"

QUEUE_DEPTH_MAX :: u32(64)
#assert(QUEUE_DEPTH_MAX * size_of(nvme.SQE) <= shared.PAGE_SIZE)


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

nvme_init :: proc(device: ^pci.Device) -> (ok: bool) {
	bar := device.bars[0]
	if !bar.isMemory || bar.addr == 0 do return false

	command := pci.config_read_u16(device, pci.CONFIG_COMMAND_OFFSET)
	pci.config_write_u16(
		device,
		pci.CONFIG_COMMAND_OFFSET,
		command | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER,
	)

	regs := Controller{([^]u8)(uintptr(bar.addr))}
	cap := read_cap(regs)
	if cap.to == 0 do return false
	if !nvme_disable(regs, cap) do return false

	if cap.mpsmin != 0 do return false
	if cap.cssNcss == 0 && cap.cssIocss == 0 do return false
	stride := doorbell_stride(cap)
	if bar.size < u64(regDoorbells + 4 * stride) do return false

	pages := dma_pages(3) or_return
	adminSq := pages
	adminCq := pages + shared.PAGE_SIZE
	ident := pages + 2 * shared.PAGE_SIZE

	n := new(Nvme)
	defer if !ok {
		nvme_disable(regs, cap)
		free(n)
		assert(syscalls.syscall_mfree_userspace([]u64{pages}) == .None)
	}

	n.regs = regs
	n.cap = cap
	n.queueDepth = min(QUEUE_DEPTH_MAX, u32(cap.mqes) + 1)
	assert(n.queueDepth >= 2)
	n.admin = {
		sq    = ([^]nvme.SQE)(uintptr(adminSq)),
		cq    = ([^]nvme.CQE)(uintptr(adminCq)),
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
		if read_csts(regs).cfs != 0 || clock.expired(enableDeadline) do return false
	}

	_ = admin_run(
		n,
		{
			cdw0 = {opc = u8(ADMIN_COMMANDS.IDENTIFY)},
			prp1 = ident,
			cdw10 = u32(IDENTIFY_CNS.CONTROLLER),
		},
	) or_return
	idCtrl := (^IdentifyController)(uintptr(ident))
	if idCtrl.sqes & 0xF != 6 || idCtrl.cqes & 0xF != 4 || idCtrl.nn == 0 do return false
	n.serial = idCtrl.sn
	n.model = idCtrl.mn

	_ = admin_run(
		n,
		{
			cdw0 = {opc = u8(ADMIN_COMMANDS.IDENTIFY)},
			prp1 = ident,
			cdw10 = u32(IDENTIFY_CNS.ACTIVE_NS_LIST),
		},
	) or_return
	n.nsid = (^ActiveNamespaceList)(uintptr(ident)).nsid[0]
	if n.nsid == 0 do return false

	_ = admin_run(
		n,
		{
			cdw0 = {opc = u8(ADMIN_COMMANDS.IDENTIFY)},
			nsid = n.nsid,
			prp1 = ident,
			cdw10 = u32(IDENTIFY_CNS.NAMESPACE),
		},
	) or_return
	idNs := (^IdentifyNamespace)(uintptr(ident))
	lbaFmtIdx := idNs.flbas & 0xF
	if lbaFmtIdx > idNs.nlbaf do return false
	if idNs.lbaf[lbaFmtIdx].lbads < 9 || idNs.lbaf[lbaFmtIdx].lbads > 12 do return false
	n.lbaSize = u32(1) << idNs.lbaf[lbaFmtIdx].lbads
	if idNs.nsze == 0 do return false
	blockCount := idNs.nsze

	granted := admin_run(
		n,
		{
			cdw0 = {opc = u8(ADMIN_COMMANDS.SET_FEATURES)},
			cdw10 = SET_FEATURES_FID_NUM_QUEUES,
			cdw11 = (NUM_QUEUES_REQUEST_MAX - 1) | (NUM_QUEUES_REQUEST_MAX - 1) << 16,
		},
	) or_return
	byDevice := min(granted & 0xFFFF, granted >> 16) + 1
	byBar := u32((bar.size - u64(regDoorbells)) / u64(2 * stride)) - 1
	n.queueCount = min(byDevice, byBar)
	if n.queueCount == 0 do return false
	n.nextQid = 1

	syscalls.syscall_debug_print_userspace("nvme: io queue pairs", u64(n.queueCount))
	syscalls.syscall_debug_print_userspace("nvme: blocks", blockCount)
	append(&disks, Disk{driver = n, blockSize = n.lbaSize, blockCount = blockCount})
	return true
}


dma_pages :: proc(count: u64) -> (base: u64, ok: bool) {
	assert(count > 0)
	regions := [1]syscalls.MMapRegion{{pageSize = ._4KB, count = count, flags = {.Write, .NX}}}
	err, addr := syscalls.syscall_mmap_userspace(regions[:])
	if err != .None do return 0, false
	assert(addr != nil)
	assert(u64(uintptr(addr)) % shared.PAGE_SIZE == 0)
	mem.zero(addr, int(count * shared.PAGE_SIZE))
	return u64(uintptr(addr)), true
}

nvme_disable :: proc(regs: Controller, cap: CAP) -> bool {
	cc := read_cc(regs)
	if cc.en != 0 {
		cc.en = 0
		write_cc(regs, cc)
	}
	deadline := ready_deadline(cap)
	for read_csts(regs).rdy != 0 {
		if clock.expired(deadline) do return false
	}
	return read_csts(regs).cfs == 0
}


nvme_queue_pair_create :: proc(n: ^Nvme) -> (info: nvme.QueueInfo, ok: bool) {
	assert(n.nextQid >= 1)
	assert(n.queueDepth >= 2 && n.queueDepth <= QUEUE_DEPTH_MAX)
	if n.nextQid > n.queueCount do return {}, false
	assert(n.nextQid <= u32(max(u16)))
	qid := u16(n.nextQid)

	pages := dma_pages(2) or_return
	defer if !ok do assert(syscalls.syscall_mfree_userspace([]u64{pages}) == .None)
	sq := pages
	cq := pages + shared.PAGE_SIZE
	sizeAndId := u32(qid) | (n.queueDepth - 1) << 16

	_ = admin_run(
		n,
		{cdw0 = {opc = u8(ADMIN_COMMANDS.CREATE_IO_CQ)}, prp1 = cq, cdw10 = sizeAndId, cdw11 = 1},
	) or_return
	_, sqOk := admin_run(
		n,
		{
			cdw0 = {opc = u8(ADMIN_COMMANDS.CREATE_IO_SQ)},
			prp1 = sq,
			cdw10 = sizeAndId,
			cdw11 = 1 | u32(qid) << 16,
		},
	)
	if !sqOk {
		_, deleted := admin_run(
			n,
			{cdw0 = {opc = u8(ADMIN_COMMANDS.DELETE_IO_CQ)}, cdw10 = u32(qid)},
		)
		assert(deleted)
		return {}, false
	}

	n.nextQid += 1
	return {
			sq = ([^]nvme.SQE)(uintptr(sq)),
			cq = ([^]nvme.CQE)(uintptr(cq)),
			sqDoorbell = doorbell(n.regs, n.cap, qid, false),
			cqDoorbell = doorbell(n.regs, n.cap, qid, true),
			depth = n.queueDepth,
			qid = qid,
			nsid = n.nsid,
			lbaSize = n.lbaSize,
		},
		true
}
