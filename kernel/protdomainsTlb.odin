package kernel
import ah "../asm_helpers"
import "../lib/spinlock"
import "base:intrinsics"
import "pmm"
tlbShootdown := struct {
	lock:  spinlock.Spinlock,
	pcid:  u32,
	acked: u32,
}{}


tlb_shootdown :: proc(pcid: u32) {
	if !cpuHasInvpcid do return
	spinlock.lock(&tlbShootdown.lock)
	defer spinlock.unlock(&tlbShootdown.lock)

	self := gs_read_cpustate()
	target := 0
	for &cpu in cpus {
		if self != nil && cpu.index == self.index do continue
		target += 1
		send_ipi(cpu.apicId, VECTOR_APIC_IPI)
	}
	intrinsics.atomic_store(&tlbShootdown.acked, 0)
	intrinsics.atomic_store(&tlbShootdown.pcid, pcid)

	ah.invpcid_asm(1, u64(pcid))

	for intrinsics.atomic_load(&tlbShootdown.acked) < u32(target) {
		ah.cpu_pause()
	}
	intrinsics.atomic_store(&tlbShootdown.pcid, 0)
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
