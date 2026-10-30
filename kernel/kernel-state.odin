package kernel
import "../lib/alloc"
import "../lib/shared"
import "base:runtime"
import "core:mem"
import "core:slice"
import "pmm"
KernelState :: struct {
	pmm:            pmm.PMM,
	heap:           alloc.Heap,
	protDomainPool: ProtDomainPool,
	pcidAllocator:  PcidAllocator,
	tlbGenCounter:  u64,
	ringPool:       RingPool,
	cpus:           []CpuState,
}

kernelState := KernelState {
	pcidAllocator = {next = 2},
}
when ODIN_TEST {
	KernelSnapshot :: struct {
		source: ^KernelState,
		state:  KernelState, // the roots, plain byte copy
		ram:    []byte, // all of test RAM: heap, page tables, free pages, user memory
	}

	kernel_ram :: proc(k: ^KernelState) -> []byte {
		assert(k.pmm.totalPages > 0)
		return slice.from_ptr(
			(^byte)(pmm.phys_to_ptr(0)),
			int(k.pmm.totalPages * shared.PAGE_SIZE),
		)
	}
	kernel_snapshot :: proc(
		k: ^KernelState,
		allocator: runtime.Allocator = context.allocator,
	) -> (
		snap: KernelSnapshot,
		err: mem.Allocator_Error,
	) {
		snap.state = k^
		snap.ram, err = slice.clone(kernel_ram(k), allocator)
		snap.source = k
		return snap, err
	}

	kernel_restore :: proc(k: ^KernelState, snap: KernelSnapshot) {
		assert(k == snap.source)
		k^ = snap.state
		ram := kernel_ram(k)
		assert(len(snap.ram) == len(ram))
		copy(ram, snap.ram)
	}

	kernel_snapshot_destroy :: proc(
		snap: KernelSnapshot,
		allocator: runtime.Allocator = context.allocator,
	) {
		delete(snap.ram, allocator)
	}
}
