// THROWAWAY: ring test, kept for reference until the user decides.
package adam
import "../lib/diskhelpers"
import "../lib/nvme"
import "../lib/pe"
import "../lib/shared"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"

FIRSTPE_BYTES := #load("../firstpe/firstpe.exe", []byte)
NTDLL_IMMITATOR_BYTES := #load("../diskimg/ntdll_immitator.dll", []byte)
FIRSTPE_WEIGHT :: u64(200_000)
RING_TEST_WAIT_CYCLES :: u64(20_000_000_000)
RING_TEST_WINDOW_FROM_END :: u64(1024)
RING_TEST_WINDOW_BLOCKS :: u64(512)
NVME_FLAGS_OFFSET :: 1
NVME_CID_OFFSET :: 2
NVME_MPTR_OFFSET :: 16
NVME_PHASE_OFFSET :: offset_of(nvme.Completion, status) + 2
NVME_STATUS_MASK :: u16(0x7FF)

RingTestParams :: struct {
	ready, done:                                       u64,
	handle:                                            int,
	nsid, lbaSize:                                     u32,
	allowedLba, deniedLba:                             u64,
	ownBuf, foreignBuf:                                u64,
	authority:                                         u64,
	writeErr, readErr, deniedReadErr, deniedWriteErr: shared.Error,
	foreignErr:                                        shared.Error,
	writeStatus, readStatus:                           u16,
	readMatch:                                         bool,
}
#assert(size_of(RingTestParams) == 120)

ring_nvme_test :: proc(disk: ^diskhelpers.Disk) {
	nvmeDisk, isNvme := &disk.driver.(diskhelpers.NvmeDisk)
	assert(isNvme)
	dev := &nvmeDisk.dev
	assert(disk.blockCount > RING_TEST_WINDOW_FROM_END)
	lo := disk.blockCount - RING_TEST_WINDOW_FROM_END
	hi := lo + RING_TEST_WINDOW_BLOCKS

	info, qErr := nvme.queue_pair_create(dev, NVME_MSIX_ROW)
	assert(qErr == .None)
	cq := u64(uintptr(info.cq))
	cqBytes := (u64(info.depth) * size_of(nvme.Completion) + shared.PAGE_SIZE - 1) &~ (shared.PAGE_SIZE - 1)

	bufRegions := [2]syscalls.MMapRegion {
		{pageSize = ._4KB, count = 1, flags = {.Present, .Write}},
		{pageSize = ._4KB, count = 1, flags = {.Present, .Write}},
	}
	mmapErr, bufs := syscalls.syscall_mmap_userspace(bufRegions[:])
	assert(mmapErr == .None)
	ownBuf := u64(uintptr(bufs))
	foreignBuf := ownBuf + syscalls.descriptor_offset(bufRegions[:], 1)

	_, ntdllOk := pe.register("ntdll.dll", NTDLL_IMMITATOR_BYTES)
	assert(ntdllOk)
	firstpe, loadOk := pe.load(FIRSTPE_BYTES)
	assert(loadOk)
	paramsRva, paramsFound := firstpe.image.exports[pe.pe_name_hash("ringTestParams")]
	assert(paramsFound)
	p := (^RingTestParams)(uintptr(firstpe.base + u64(paramsRva)))

	DENY :: 32
	READ_PATH :: 28
	WRITE_PATH :: 30
	rules := [DENY]syscalls.ContractRule {
		{op = .Imm, a = 7, imm = 0},
		{op = .Load8, a = 2, imm = NVME_FLAGS_OFFSET},
		{op = .Jne, a = 2, b = 7, imm = DENY},
		{op = .Load32, a = 2, imm = u64(offset_of(nvme.Command, namespaceId))},
		{op = .Imm, a = 3, imm = u64(dev.nsid)},
		{op = .Jne, a = 2, b = 3, imm = DENY},
		{op = .Load64, a = 2, imm = NVME_MPTR_OFFSET},
		{op = .Jne, a = 2, b = 7, imm = DENY},
		{op = .Load64, a = 2, imm = u64(offset_of(nvme.Command, dataAddr2))},
		{op = .Jne, a = 2, b = 7, imm = DENY},
		{op = .Load16, a = 2, imm = u64(offset_of(nvme.Command, args) + offset_of(nvme.IoArgs, blockCountMinus1))},
		{op = .Jne, a = 2, b = 7, imm = DENY},
		{op = .Load64, a = 2, imm = u64(offset_of(nvme.Command, args) + offset_of(nvme.IoArgs, startBlock))},
		{op = .Imm, a = 3, imm = lo},
		{op = .Jlt, a = 2, b = 3, imm = DENY},
		{op = .Imm, a = 3, imm = hi},
		{op = .Jge, a = 2, b = 3, imm = DENY},
		{op = .Load64, a = 4, imm = u64(offset_of(nvme.Command, dataAddr))},
		{op = .Imm, a = 3, imm = shared.PAGE_SIZE - 1},
		{op = .And, a = 3, b = 4},
		{op = .Jne, a = 3, b = 7, imm = DENY},
		{op = .Imm, a = 5, imm = u64(dev.lbaSize)},
		{op = .Load8, a = 2, imm = 0},
		{op = .Imm, a = 3, imm = u64(nvme.IoOpcode.Read)},
		{op = .Jeq, a = 2, b = 3, imm = READ_PATH},
		{op = .Imm, a = 3, imm = u64(nvme.IoOpcode.Write)},
		{op = .Jeq, a = 2, b = 3, imm = WRITE_PATH},
		{op = .Jeq, a = 7, b = 7, imm = DENY},
		{op = .HasPermW, a = 4, b = 5},
		{op = .Accept},
		{op = .HasPermR, a = 4, b = 5},
		{op = .Accept},
	}
	assert(rules[READ_PATH].op == .HasPermW && rules[WRITE_PATH].op == .HasPermR)

	desc := syscalls.RingDesc {
		authorityPtr = u64(uintptr(&p.authority)),
		sq = {
			phys = u64(uintptr(info.sq)),
			entrySize = size_of(nvme.Command),
			depth = u64(info.depth),
			doorbell = u64(uintptr(info.sqDoorbell)),
			tokenOffset = NVME_CID_OFFSET,
		},
		cq = {
			phys = cq,
			entrySize = size_of(nvme.Completion),
			depth = u64(info.depth),
			doorbell = u64(uintptr(info.cqDoorbell)),
			tokenOffset = u64(offset_of(nvme.Completion, status)),
			phaseOffset = u64(NVME_PHASE_OFFSET),
			phaseBit = 0,
			statusOffset = u64(NVME_PHASE_OFFSET),
		},
		domainCap = u64(info.depth) - 1,
		rulesPtr = u64(uintptr(&rules)),
		rulesCount = len(rules),
	}
	syscalls.syscall_debug_print_userspace("ring nvme qid", u64(info.qid))
	syscalls.syscall_debug_print_userspace("ring nvme depth", u64(info.depth))
	syscalls.syscall_debug_print_userspace("ring nvme sq", desc.sq.phys)
	syscalls.syscall_debug_print_userspace("ring nvme cq", cq)
	syscalls.syscall_debug_print_userspace("ring nvme sq doorbell", desc.sq.doorbell)
	syscalls.syscall_debug_print_userspace("ring nvme cq doorbell", desc.cq.doorbell)
	syscalls.syscall_debug_print_userspace("ring nvme params", u64(uintptr(p)))
	syscalls.syscall_debug_print_userspace("ring nvme lo", lo)
	syscalls.syscall_debug_print_userspace("ring nvme nsid", u64(dev.nsid))
	syscalls.syscall_debug_print_userspace("ring nvme lbaSize", u64(dev.lbaSize))
	handle, createErr := syscalls.syscall_ring_create_userspace(&desc)
	syscalls.syscall_debug_print_userspace("ring nvme create err", u64(createErr))
	syscalls.syscall_debug_print_userspace("ring nvme handle", u64(handle))
	assert(createErr == .None)

	p^ = {
		handle     = handle,
		nsid       = dev.nsid,
		lbaSize    = dev.lbaSize,
		allowedLba = lo,
		deniedLba  = 0,
		ownBuf     = ownBuf,
		foreignBuf = foreignBuf,
	}

	infos := userschedule.cpu_infos((^userschedule.CpuInfoPage)(uintptr(userschedule.CPU_INFO_ADDR)))
	selfCpu := syscalls.cpu_current_index()
	cpu := selfCpu
	for &cpuInfo, idx in infos {
		if u32(idx) != selfCpu && intrinsics.atomic_load(&cpuInfo.online) {
			cpu = u32(idx)
			break
		}
	}

	child, runErr := pe.pe_run(&firstpe, firstpe.image.entryRva, cpu, FIRSTPE_WEIGHT)
	syscalls.syscall_debug_print_userspace("ring nvme pe_run err", u64(runErr))
	syscalls.syscall_debug_print_userspace("ring nvme child", u64(child))
	syscalls.syscall_debug_print_userspace("ring nvme child cpu", u64(cpu))
	assert(runErr == .None)
	grants := [2]syscalls.MemRegion {
		{phys = cq, logical = cq, size = cqBytes, pageSize = ._4KB, flags = {.NX}},
		{phys = ownBuf, logical = ownBuf, size = shared.PAGE_SIZE, pageSize = ._4KB, flags = {.Write, .NX}},
	}
	editErr := syscalls.syscall_prot_domain_edit_userspace(child, grants[:], .Add)
	syscalls.syscall_debug_print_userspace("ring nvme grant err", u64(editErr))
	assert(editErr == .None)
	intrinsics.atomic_store(&p.ready, 1)
	syscalls.syscall_debug_print_userspace("ring nvme ready set", p.ready)

	deadline := u64(intrinsics.read_cycle_counter()) + RING_TEST_WAIT_CYCLES
	syscalls.syscall_debug_print_userspace("ring nvme now", u64(intrinsics.read_cycle_counter()))
	syscalls.syscall_debug_print_userspace("ring nvme deadline", deadline)
	for intrinsics.atomic_load(&p.done) == 0 {
		doneErr := syscalls.syscall_wait_on_userspace(&p.done, 0, deadline)
		syscalls.syscall_debug_print_userspace("ring nvme done wait_on err", u64(doneErr))
		syscalls.syscall_debug_print_userspace("ring nvme now", u64(intrinsics.read_cycle_counter()))
		syscalls.syscall_debug_print_userspace("ring nvme p.done", p.done)
		if doneErr == .Timeout do break
	}
	syscalls.syscall_debug_print_userspace("ring nvme done", p.done)
	syscalls.syscall_debug_print_userspace("ring nvme writeErr", u64(p.writeErr))
	syscalls.syscall_debug_print_userspace("ring nvme writeStatus", u64(p.writeStatus))
	syscalls.syscall_debug_print_userspace("ring nvme readErr", u64(p.readErr))
	syscalls.syscall_debug_print_userspace("ring nvme readStatus", u64(p.readStatus))
	syscalls.syscall_debug_print_userspace("ring nvme readMatch", u64(p.readMatch))
	syscalls.syscall_debug_print_userspace("ring nvme deniedReadErr", u64(p.deniedReadErr))
	syscalls.syscall_debug_print_userspace("ring nvme deniedWriteErr", u64(p.deniedWriteErr))
	syscalls.syscall_debug_print_userspace("ring nvme foreignErr", u64(p.foreignErr))

	assert(p.done == 1)
	assert(p.writeErr == .None && (p.writeStatus >> 1) & NVME_STATUS_MASK == 0)
	assert(p.readErr == .None && (p.readStatus >> 1) & NVME_STATUS_MASK == 0 && p.readMatch)
	assert(p.deniedReadErr == .Denied && p.deniedWriteErr == .Denied && p.foreignErr == .Denied)

	for syscalls.syscall_grant_edit_userspace(child, cpu, FIRSTPE_WEIGHT) == .None do intrinsics.cpu_relax()
	assert(syscalls.syscall_ring_destroy_userspace(handle) == .None)
	assert(syscalls.syscall_ring_destroy_userspace(handle) == .InvalidHandle)
	assert(syscalls.syscall_prot_domain_destroy_userspace(child) == .None)

	_, sqDeleteErr := nvme.admin_execute_command(
		dev,
		{header = {opcode = u8(nvme.ADMIN_COMMANDS.DELETE_IO_SQ)}, args = {deleteQueue = {queueId = info.qid}}},
	)
	assert(sqDeleteErr == .None)
	_, cqDeleteErr := nvme.admin_execute_command(
		dev,
		{header = {opcode = u8(nvme.ADMIN_COMMANDS.DELETE_IO_CQ)}, args = {deleteQueue = {queueId = info.qid}}},
	)
	assert(cqDeleteErr == .None)

	assert(syscalls.mem_free_userspace(ownBuf) == .None)
	assert(syscalls.mem_free_userspace(foreignBuf) == .None)
	syscalls.syscall_debug_print_userspace("ring nvme test ok")
}
