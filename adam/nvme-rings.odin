package adam
import "../lib/diskhelpers"
import "../lib/nvme"
import "../lib/shared"
import "../lib/syscalls"
import "../lib/userschedule"
import "base:intrinsics"
import "core:mem"
import "core:slice"

nvme_rings_destroy :: proc(dev: ^nvme.Device, rings: ^diskhelpers.NvmeRings) -> shared.Error {
	for &r in rings.v {
		if r == {} do continue
		syscalls.syscall_ring_destroy_userspace(r.handle) or_return
		nvme.queue_pair_destroy(dev, r.info) or_return
		r = {}
	}

	if rings.authority != nil {
		syscalls.mem_free_userspace(u64(uintptr(raw_data(rings.authority)))) or_return
		rings.authority = nil
	}
	delete(rings.v)
	rings^ = {}
	return .None

}

nvme_rings_create :: proc(
	dev: ^nvme.Device,
	blockCount: u64,
) -> (
	rings: diskhelpers.NvmeRings,
	err: shared.Error,
) {
	cpus := userschedule.cpu_infos(
		(^userschedule.CpuInfoPage)(uintptr(userschedule.CPU_INFO_ADDR)),
	)
	n := len(cpus)
	assert(n >= 1)

	authoritySize := u64(dev.queueDepth) - 1
	authorityBytes := u64(n) * authoritySize
	authorityPages := (authorityBytes + shared.PAGE_SIZE - 1) / shared.PAGE_SIZE
	authorityPtr := syscalls.syscall_mmap_userspace(
		{{pageSize = ._4KB, count = authorityPages, flags = {.Write}}},
	) or_return
	rings.authority = slice.from_ptr((^byte)(authorityPtr), int(authorityBytes))

	defer if err != .None {
		dErr := nvme_rings_destroy(dev, &rings)
		assert(dErr == .None)
	}
	aErr: mem.Allocator_Error
	rings.v, aErr = make([]diskhelpers.NvmeRing, n)
	if aErr != .None do return rings, .OutOfMemory

	rules := nvme.contract_rules(dev.nsid, dev.lbaSize, 0, blockCount)

	_, cqPages := nvme.queue_pair_pages(dev)
	for i in 0 ..< n {
		info, qErr := nvme.queue_pair_create(dev, NVME_MSIX_ROW)
		if qErr == .NvmeIoQueuesExhausted && i > 0 do break
		if qErr != .None do return rings, qErr
		authority := u64(uintptr(&rings.authority[u64(i) * authoritySize]))
		desc := nvme.ring_desc(info, authority, authoritySize, rules[:])
		handle, cErr := syscalls.syscall_ring_create_userspace(&desc)
		if cErr != .None {
			dErr := nvme.queue_pair_destroy(dev, info)
			assert(dErr == .None)
			return rings, cErr
		}
		rings.v[i] = diskhelpers.NvmeRing{handle, info, cqPages * shared.PAGE_SIZE}
	}
	return rings, .None
}
nvme_rings_grant :: proc(rings: diskhelpers.NvmeRings, child: int, slots: []u64) -> shared.Error {
	assert(len(slots) == len(rings.v))
	buf: [syscalls.MAX_REGIONS_PER_CALL]syscalls.MemRegion
	count: int
	for slot, i in slots {
		if slot == 0 do continue
		ring := rings.v[i]
		assert(ring != {})
		authoritySize := u64(ring.info.depth - 1)
		assert(slot <= authoritySize)
		if count + 2 > len(buf) {
			syscalls.syscall_prot_domain_edit_userspace(child, buf[:count], .Add) or_return
			count = 0
		}
		authority := u64(uintptr(&rings.authority[u64(i) * authoritySize]))
		cq := u64(uintptr(ring.info.cq))
		buf[count] = {
			phys    = authority,
			logical = authority,
			size    = slot,
			flags   = {.Write},
		}
		buf[count + 1] = {
			phys     = cq,
			logical  = cq,
			size     = ring.cqBytes,
			pageSize = ._4KB,
			flags    = {.Present, .NX},
		}
		count += 2

	}
	if count > 0 do syscalls.syscall_prot_domain_edit_userspace(child, buf[:count], .Add) or_return
	return .None

}
