package kernel
import ah "../asm_helpers"
import "../lib/spinlock"
import "base:intrinsics"
import "pmm"
import "print"
tlb_wait_domain_flushed :: proc "contextless" (domain: ^ProtectionDomain) {
	self := gs_read_cpustate()
	for &cpu in cpus {
		if &cpu == self do continue
		start := intrinsics.atomic_load(&cpu.tlbEpoch)
		for intrinsics.atomic_load(&cpu.currentGrant.domain) == domain &&
		    intrinsics.atomic_load(&cpu.tlbEpoch) == start {
			intrinsics.atomic_add(&self.tlbEpoch, 1)
			intrinsics.cpu_relax()
		}
	}
	ah.write_cr3(ah.read_cr3())
}


KERNEL_PCID :: u32(1)
PCID_MAX :: u32(4096)

pcidAllocator := struct {
	lock: spinlock.Spinlock,
	next: u32,
	free: [dynamic]u32,
} {
	next = 2,
}

pcid_alloc :: proc() -> u32 {
	if !cpuHasPCID do return 0
	spinlock.lock(&pcidAllocator.lock)
	defer spinlock.unlock(&pcidAllocator.lock)
	if len(pcidAllocator.free) > 0 do return pop(&pcidAllocator.free)
	if pcidAllocator.next >= PCID_MAX do return 0
	pcid := pcidAllocator.next
	pcidAllocator.next += 1
	return pcid
}


pcid_free :: proc(pcid: u32) {
	if !cpuHasPCID do return
	if pcid == 0 do return
	spinlock.lock(&pcidAllocator.lock)
	defer spinlock.unlock(&pcidAllocator.lock)
	append(&pcidAllocator.free, pcid)
}

PCID_NOFLUSH_BIT :: u64(1) << 63

domain_switch_cr3 :: proc "contextless" (domain: ^ProtectionDomain) {
	if !cpuHasPCID || domain.pcid == 0 {
		ah.write_cr3(domain.pml4)
		return
	}
	ah.write_cr3(domain.pml4 | u64(domain.pcid) | PCID_NOFLUSH_BIT)
}

kernel_switch_cr3 :: proc "contextless" () {
	if !cpuHasPCID {
		ah.write_cr3(pmm.kernelPML4)
		return
	}
	ah.write_cr3(pmm.kernelPML4 | u64(KERNEL_PCID) | PCID_NOFLUSH_BIT)
}
