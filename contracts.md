CONTRACTS

problem: no iommu, no lba perms, no sr-iov. a device dmas wherever its commands say.
anything with its own mmu we can translate our perms into (gpu per-context page tables) does NOT use contracts.
contracts are for devices that take raw addresses in commands.

idea: device memory (rings, registers) is mediated. clients never write it. they hand bytes to the kernel,
the kernel copies them, runs the contract on the copy, checks every address against the SUBMITTER's perms, writes the copy to the device.
kernel knows no device. adam (device owner) writes contracts. kernel only guarantees contracts can't be used to escape perms.

disk blocks, ports, endpoints = fake phys windows (DISK_BASE + lba<<blockShift, PORT_BASE + proto<<16 + port, ...).
granted/split like ram via prot_domain_edit. one perm system for everything.

CONTRACT = []Rule. 8 u64 registers. pc only moves forward. running off the end = deny.

RuleOp :: enum u8 {
	Load,    // r[a] = field
	Imm,     // r[a] = imm
	Add,     // r[a] += r[b], overflow -> deny
	Sub,     // r[a] -= r[b], underflow -> deny
	Shl,     // r[a] <<= r[b], overflow -> deny
	Shr,     // r[a] >>= r[b]
	JumpIf,  // cmp(r[a], r[b]) -> pc = imm, imm > pc
	Accept,
	HasPerm, // submitter holds rights on [r[a], r[a]+r[b]), pin it
	Copy,    // submitter holds Read on [r[a], r[a]+r[b]), copy into kernel buffer imm, pin buffer, r[a] = buffer phys
	List,    // buffer field.buf: r[b] entries, stride imm, addr = field, len = r[a]. addr % len != 0 -> deny. HasPerm(addr, len, rights) on each.
	         // chainEvery = imm2 (0 = none): every chainEvery-th entry, if more remain, = next list page -> HasPerm Read + Copy it, continue there.
	         // r[b] > contract.maxListEntries -> deny
	Store,   // field = r[a], into the kernel copy
	Retire,  // completion: loan with token r[a] ends
	Deliver, // rx: hand current entry to holder of key r[a], no holder -> drop
}

Cmp :: enum u8 { Eq, Ne, Lt, Le, Gt, Ge }
Right :: enum u8 { Read, Write }

Field :: struct {
	buf:       u8,  // 0 = slot copy, 1.. = Copy buffers
	offset:    u16,
	size:      u8,  // 1 2 4 8
	shift:     u8,
	bigEndian: bool,
	mask:      u64,
}
// Load:  r = (read(buf, offset, size) >> shift) & mask
// Store: field = field &~ (mask << shift) | (r & mask) << shift

Rule :: struct {
	op:     RuleOp,
	a, b:   u8,
	cmp:    Cmp,
	rights: bit_set[Right;u8],
	field:  Field,
	imm:    u64,
	imm2:   u64,
}

validated once at create, runtime is a dumb switch:
- a, b < 8. field size in {1,2,4,8}, offset+size inside its buffer, mask fits size.
- JumpIf imm > pc and <= len(rules).
- Copy buffer index < MAX_BUFFERS, Copy len <= one page (chained list pages are copied one page at a time by List).
- registers indexed & 7 (spectre).
- no backward jumps -> every run <= len(rules) steps + maxListEntries List entries (set by adam from the device limit, nvme: MDTS pages). not turing complete.

what the kernel guarantees (not device correctness):
- contract author gains nothing: can only attach to memory it holds, and owning a dma device without iommu = all ram anyway.
- submitter can't escape: device memory not mapped writable to clients, kernel copies before checking, kernel owns doorbells/tokens,
  every address checked against the submitter's own perms.
- engine can't hurt the kernel: touches only registers + slot copy + its buffers, always halts.
- a contract that forgets a ptr field is adam's bug, not a kernel hole.

PINS (loans)
- HasPerm, Copy, List pin what they checked. deny releases them. Retire ends them.
- free of a pinned page -> quarantine (drop succeeds, pmm reuses after unpin).
- revoke of a pinned page (others still hold it) -> .Busy.
- Copy buffers live per in-flight slot until Retire (device reads them).
- hung device: pins stuck until adam resets the controller.

ATTACH POINTS
1. ring: {slots, stride, depth, doorbell, arm, token field, submit contract, completion contract}.
   arm kinds: TailDoorbell (kernel writes tail) | CycleBit (kernel writes cycle bit last, constant doorbell value) | SlotBit (doorbell = bitmask of issued slots).
   kernel state: tail, inFlight, slot states {Free, Written, InFlight}, per-slot pins + buffers.
   why kernel owns this: writing a slot the device still reads = torn unchecked command. client-picked tail = replay of old slots whose pins ended.
2. register: one mmio register write = slot of 4/8 bytes, contract runs, kernel writes. for ptr registers (hda BDL base, etc).
3. rx: contract runs per received entry, ends in Deliver. kernel copies (or flips page) into the key holder's rx ring.
   receive registration for key K requires HasPerm(K) at registration.

OPEN
- completion source per device differs: nvme CQ entries (phase bit, CID), e1000 DD bit inside own slot, ahci PxCI bits clearing.
  candidate: kernel runs the completion contract once per in-flight slot, r0 = slot index, r1 = token, buf 0 = completion source bytes.
- rx buffer posting: who owns rx buffers before demux (owner pool vs kernel pool), copy vs page flip.
- token field: nvme has CID, e1000 has none (token = slot index, in order).

HARDWARE (2011+ consumer, ~2015 gpus)

never contracts, trusted owner only (adam):
- pci config space, BARs (remapping a BAR over ram), MSI/MSI-X tables (no interrupt remapping -> forged interrupts), admin/command queues, controller reset.

own mmu -> translate perms, no contracts:
- gpu intel broadwell+ (full ppgtt), amd gcn+ (vmid). per-context page tables from our perms, command buffers unchecked.
- older gpus (sandy/ivy/haswell: global gtt only): trusted owner.
- gop framebuffer: plain memory perms.

nvme (ring, TailDoorbell, CQ completion with CID token):
- opcodes allow: read 0x02, write 0x01, flush 0x00. everything else deny. admin queue owner only.
- fuse/psdt = 0 (no fused, no SGL). MPTR = 0. NSID fixed.
- disk range: slba<<bs + DISK_BASE, (nlb+1)<<bs. read needs disk R + ram W, write the reverse.
- PRP1: page of (prp1 &~ (P-1)). PRP2: unused / second page / PRP list.
- PRP list: count = ((prp1 & (P-1)) + total + P-1) >> log2(P) - 1. Copy list, List stride 8 len P, Store prp2 = copy.
- MDTS caps transfer. list chains: List chainEvery = 512 (P / 8), maxListEntries from MDTS (MDTS 0 = adam picks the bound, flagged software limit).

ahci (ring, SlotBit on PxCI, completion = PxCI bit clear):
- 32 slots per port. header (32B) points to command table (CFIS + PRDT) -> Copy table, Store CTBA = copy.
- FIS command allow: READ DMA EXT 0x25, WRITE DMA EXT 0x35, FLUSH CACHE EXT 0xEA. ATAPI deny.
- lba48 split in 3-byte halves: two Loads + Shl + Add.
- PRDT entry 16B {dba u64, dbc u32 (bytes-1, 22 bits)} -> List with len field.
- header PRDTL = entry count, W bit must match command direction.
- NCQ (PxSACT, FPDMA) later.

e1000 / e1000e (ring, TailDoorbell, completion = DD bit in own descriptor, in order):
- tx legacy desc 16B {addr, len, cso, cmd, sta, css, special}: HasPerm(addr, len, Read).
- tx context descriptors: no address, allow by type.
- rx desc {addr, len, csum, status, errors, special}: buffers posted by rx owner, demux via rx contract + Deliver.
- 82574 has 2 rx queues (rss), no flow steering we can rely on.

rtl8168/8111 ethernet (10ec:8168, dev laptop) (ring, CycleBit-like: OWN bit written last, constant doorbell TxPoll NPQ, completion = device clears OWN in own descriptor, in order):
- desc 16B {opts1 u32 (OWN bit 31, EOR bit 30, FS bit 29, LS bit 28, len), opts2 u32, addr u64}.
- tx: HasPerm(addr, len, Read). EOR (ring wrap) set by kernel, client EOR deny.
- rx: buffers posted by rx owner with OWN set, demux via rx contract + Deliver.
- MSI / MSI-X, no pins.

intel cnvi wifi (8086:7a70, iwlwifi family, dev laptop):
- firmware blob + command queue owned by adam.
- tx frame descriptor = up to 20 buffers {addr, len} -> List. details later.

xhci (ring per endpoint, CycleBit, doorbell value = endpoint id):
- transfer TRB allow: Normal, Setup/Data/Status (control), Isoch. link TRBs from clients deny, kernel handles wrap.
- data buffer ptr + len -> HasPerm. IDT bit = inline data, no ptr -> skip check via JumpIf.
- command ring, device/endpoint contexts, scratchpad: owner only.
- event ring shared by all endpoints -> rx-style Deliver, key = slot + endpoint.

hda audio (register + list):
- stream BDL {addr u64, len u32, ioc u32} entries -> Copy + List.
- stream BDPL/BDPU registers = register contract (ptr field). position buffer ptr same.
- CORB/RIRB codec verbs: owner only (or contract allowlisting verbs later).
