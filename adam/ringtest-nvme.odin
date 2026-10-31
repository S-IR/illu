// THROWAWAY: ring test, kept for reference until the user decides.
package adam
import "../lib/diskhelpers"
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

NVME_STATUS_MASK :: u16(0x7FF)

RingTestParams :: struct {
	ready, done:                                      u64,
	handle, otherHandle:                              int,
	nsid, lbaSize:                                    u32,
	allowedLba, deniedLba:                            u64,
	ownBuf, foreignBuf:                               u64,
	authority, cq:                                    u64,
	capAccepted:                                      u64,
	writeErr, readErr, deniedReadErr, deniedWriteErr: shared.Error,
	foreignErr, capErr, capFullErr, otherErr:         shared.Error,
	authWriteErr, authReadErr, cqWriteErr, cqReadErr: shared.Error,
	writeStatus, readStatus:                          u16,
	readMatch, authMatch:                             bool,
}
#assert(size_of(RingTestParams) == 200)

ring_nvme_test :: proc(disk: ^diskhelpers.Disk) {
	nvmeDisk, isNvme := &disk.driver.(diskhelpers.NvmeDisk)
	assert(isNvme)
	dev := &nvmeDisk.dev
	rings := &nvmeDisk.rings
	assert(disk.blockCount > RING_TEST_WINDOW_FROM_END)

	infos := userschedule.cpu_infos(
		(^userschedule.CpuInfoPage)(uintptr(userschedule.CPU_INFO_ADDR)),
	)
	assert(len(rings.v) == len(infos))
	ringCount: u64
	for r in rings.v do if r != {} do ringCount += 1
	syscalls.syscall_debug_print_userspace("ring nvme cpus", u64(len(infos)))
	syscalls.syscall_debug_print_userspace("ring nvme rings", ringCount)

	selfCpu := syscalls.cpu_current_index()
	cpu := selfCpu
	for &cpuInfo, idx in infos {
		if u32(idx) != selfCpu && intrinsics.atomic_load(&cpuInfo.online) {
			cpu = u32(idx)
			break
		}
	}
	assert(cpu != selfCpu)
	ring := rings.v[cpu]
	other := rings.v[selfCpu]
	assert(ring != {} && other != {})
	assert(ring.handle != other.handle)
	authority := u64(uintptr(&rings.authority[u64(cpu) * u64(ring.info.depth - 1)]))

	bufRegions := [2]syscalls.MMapRegion {
		{pageSize = ._4KB, count = 1, flags = {.Present, .Write}},
		{pageSize = ._4KB, count = 1, flags = {.Present, .Write}},
	}
	bufs, mmapErr := syscalls.syscall_mmap_userspace(bufRegions[:])
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

	p^ = {
		handle      = ring.handle,
		otherHandle = other.handle,
		nsid        = dev.nsid,
		lbaSize     = dev.lbaSize,
		allowedLba  = disk.blockCount - RING_TEST_WINDOW_FROM_END,
		deniedLba   = disk.blockCount,
		ownBuf      = ownBuf,
		foreignBuf  = foreignBuf,
		authority   = authority,
		cq          = u64(uintptr(ring.info.cq)),
	}

	child, runErr := pe.pe_run(&firstpe, firstpe.image.entryRva, cpu, FIRSTPE_WEIGHT)
	syscalls.syscall_debug_print_userspace("ring nvme pe_run err", u64(runErr))
	assert(runErr == .None)

	slots := make([]u64, len(rings.v), context.temp_allocator)
	slots[cpu] = 1
	grantErr := nvme_rings_grant(rings^, child, slots)
	syscalls.syscall_debug_print_userspace("ring nvme grant err", u64(grantErr))
	assert(grantErr == .None)
	bufGrant := [1]syscalls.MemRegion {
		{
			phys = ownBuf,
			logical = ownBuf,
			size = shared.PAGE_SIZE,
			pageSize = ._4KB,
			flags = {.Present, .Write, .NX},
		},
	}
	editErr := syscalls.syscall_prot_domain_edit_userspace(child, bufGrant[:], .Add)
	assert(editErr == .None)
	intrinsics.atomic_store(&p.ready, 1)

	deadline := u64(intrinsics.read_cycle_counter()) + RING_TEST_WAIT_CYCLES
	for intrinsics.atomic_load(&p.done) == 0 {
		if syscalls.syscall_wait_on_userspace(&p.done, 0, deadline) == .Timeout do break
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
	syscalls.syscall_debug_print_userspace("ring nvme capAccepted", p.capAccepted)
	syscalls.syscall_debug_print_userspace("ring nvme capErr", u64(p.capErr))
	syscalls.syscall_debug_print_userspace("ring nvme capFullErr", u64(p.capFullErr))
	syscalls.syscall_debug_print_userspace("ring nvme otherErr", u64(p.otherErr))
	syscalls.syscall_debug_print_userspace("ring nvme authWriteErr", u64(p.authWriteErr))
	syscalls.syscall_debug_print_userspace("ring nvme authReadErr", u64(p.authReadErr))
	syscalls.syscall_debug_print_userspace("ring nvme authMatch", u64(p.authMatch))
	syscalls.syscall_debug_print_userspace("ring nvme cqReadErr", u64(p.cqReadErr))
	syscalls.syscall_debug_print_userspace("ring nvme cqWriteErr", u64(p.cqWriteErr))

	assert(p.done == 1)
	assert(p.writeErr == .None && (p.writeStatus >> 1) & NVME_STATUS_MASK == 0)
	assert(p.readErr == .None && (p.readStatus >> 1) & NVME_STATUS_MASK == 0 && p.readMatch)
	assert(p.deniedReadErr == .Denied && p.deniedWriteErr == .Denied && p.foreignErr == .Denied)
	assert(p.capErr == .None && p.capAccepted == 1 && p.capFullErr == .RingFull)
	assert(p.otherErr == .NoPermission)
	assert(p.authWriteErr == .None && p.authReadErr == .None && p.authMatch)
	assert(p.cqReadErr == .None && p.cqWriteErr == .Denied)

	for syscalls.syscall_grant_edit_userspace(child, cpu, FIRSTPE_WEIGHT) == .None do intrinsics.cpu_relax()
	assert(syscalls.syscall_prot_domain_destroy_userspace(child) == .None)

	assert(syscalls.mem_free_userspace(ownBuf) == .None)
	assert(syscalls.mem_free_userspace(foreignBuf) == .None)
	syscalls.syscall_debug_print_userspace("ring nvme test ok")
}
