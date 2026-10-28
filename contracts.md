CONTRACTS

problem: no iommu, no lba perms, no sr-iov. a device dmas wherever its commands say.
anything with its own mmu we can translate our perms into (gpu per-context page tables) does NOT use contracts.
contracts are for devices that take raw addresses in commands.

idea: device memory (rings, registers) is mediated. clients never write it. they hand bytes to the kernel,
the kernel copies them, runs the contract on the copy, checks every address against the SUBMITTER's perms, writes the copy to the device.
kernel knows no device. adam (device owner) writes contracts. kernel only guarantees contracts can't be used to escape perms.

disk blocks, ports, endpoints = fake phys windows (DISK_BASE | diskId<<44 | lba<<blockShift, PORT_BASE + proto<<16 + port, ...).
windows sit above the real phys max. one disk window per controller + namespace.
granted/split like ram via prot_domain_edit. one perm system for everything.

CONTRACT (decided 2026-10-26, code: lib/syscalls/contracts.odin, kernel/contracts.odin)
contracted memory = MemoryResource with rContractRules / wContractRules ([]ContractRule). byte granular, never mapped (flags = {}, no .Present).
plain access (user_range_accessible, wait_on, DebugPrint) already rejects it because .Present is missing.
rules copied into the kernel per ContractCreate. one owner per copy, no refcount. freed when the resource dies (Delete, protdomain_free).
regrant: open. today the grant paths refuse it only by accident (flags {}); add an explicit check + assert in resource_granted.
contract_access must hold the caller's domain read lock for the whole run (Delete frees rules under domains_write_lock).

syscalls:
- ContractCreate(handle, phys, size, descPtr). desc = {rPtr, rCount, wPtr, wCount}. caller owns [phys, phys+size) with W, owner has no rules.
  target gets an unmapped resource with the rules, same underlay (increment).
- ContractMemoryAccess(dst, buf, len, dir). len <= CONTRACT_ACCESS_MAX (64 = nvme SQE).
  write: copy bytes in, run wRules, store to dst (len 4/8 = one volatile store). read: run rRules BEFORE the load (read-to-clear regs), load, copy out.
  empty rule set = that direction denied. dst+len checked against the resource bounds.
- no max rule count: only check count * 16 overflow. kernel memory quota is a general later problem (resources, grants, sleepers grow too).

engine: 8 u64 registers (r0 = dst offset, r1 = len preloaded), pc forward only, off the end = deny. not turing complete on purpose.
ContractRule :: {imm: u64, op: ContractOp (u8), a, b: u8} = 16 bytes. a/b are register indices < 8.
ops:
	Load8/16/32/64  r[a] = LE bytes of the access copy at imm. write rules only. imm + width <= len at runtime.
	Store64         copy at imm = r[a]. write rules only.
	Imm             r[a] = imm
	Add Sub Shl Shr And   r[a] op= r[b]. add overflow / sub underflow / shl bits lost or r[b] >= 64 -> deny.
	Jeq Jne Jlt Jge unsigned cmp r[a], r[b] -> pc = imm. imm > pc, imm <= len(rules) (== len = deny). Jle/Jgt = swap a b.
	Accept
	HasPermR/W      submitter holds R/W on [r[a], r[a]+r[b]), pin it
	Copy            user [r[a], +r[b]) -> kernel buffer imm, pin, r[a] = buffer phys. buffers NOT designed yet.
	ListR/W         buffer r[a], r[b] entries, stride imm (8..PAGE_SIZE). implicit r6 = entry len, r7 = chain period (0 none).
	                entry addr % len != 0 -> deny. count > maxListEntries (from MDTS) -> deny.
no Bswap / Deliver yet (no big endian device, rx later). unused fields must be 0 (validate).
nvme: no transfer cap besides MDTS. PRP2 = unused / second page / list (Copy + List).

what the kernel guarantees (not device correctness):
- contract author gains nothing: can only attach to memory it holds, and owning a dma device without iommu = all ram anyway.
- submitter can't escape: device memory not mapped writable to clients, kernel copies before checking, kernel owns doorbells/tokens,
  every address checked against the submitter's own perms.
- engine can't hurt the kernel: touches only registers + slot copy + its buffers, always halts.
- a contract that forgets a ptr field is adam's bug, not a kernel hole.

PINS (loans)
- HasPerm, Copy, List pin what they checked: atomic pinCount on the submitter's MemoryResource covering the range. deny releases them. reap releases them.
- ProtDomainEdit Delete / Transfer / split of a pinned resource -> .Busy. no quarantine.
- domain destroy must succeed: its pinned resources move to a kernel zombie list, freed at reap.
- disk windows pin the same way: a revoke can't land an in-flight write on reassigned blocks.
- Copy buffers live per in-flight slot until reap (device reads them).
- hung device: pins stuck until adam resets the controller.

ATTACH POINTS
1. ring: {slots, stride, depth, doorbell, arm, completion, submit contract}.
   arm kinds: TailDoorbell (kernel writes tail) | CycleBit (kernel writes cycle bit last, constant doorbell value) | SlotBit (doorbell = bitmask of issued slots).
   completion kinds (how the device says "done", picked at create, no contract):
     CqPhase{entrySize, phase field, token field}  nvme: entry in a completion queue, phase bit flips each lap, token = CID.
     OwnSlotBit{field}                             e1000/rtl: done bit in the slot itself, in order, token = slot index.
     BitmaskReg{register}                          ahci: PxCI bit clears, token = slot index.
   kernel state: tail, inFlight, slot states {Free, Written, InFlight}, per-slot pins + buffers.
   why kernel owns this: writing a slot the device still reads = torn unchecked command. client-picked tail = replay of old slots whose pins ended.
   completion memory (CQ) is kernel-read only, clients get it mapped R (enough for wait_on). CQ head doorbell is kernel-owned.
     why: a client that writes the CQ forges a completion -> kernel unpins a page the device still DMAs into -> page leaks to another domain.
   syscalls:
     ring_create(desc): caller must hold W on slots, completion memory, doorbell. returns a ring authority byte.
     ring_submit(ring, entries, n): per entry copy, run contract, place. one doorbell write at the end. returns accepted count + first deny.
     ring_reap(ring, out, max): kernel reads completions, releases pins + buffers, writes CQ head doorbell, returns tokens + status.
     using a ring needs W on its authority byte (same pattern as ProtectionDomain.authorityPtr).
2. register: one mmio register write = slot of 4/8 bytes, contract runs, kernel writes. for ptr registers (hda BDL base, etc).
3. rx: contract runs per received entry, ends in Deliver. kernel copies (or flips page) into the key holder's rx ring.
   receive registration for key K requires HasPerm(K) at registration.

OPEN
- rx buffer posting: who owns rx buffers before demux (owner pool vs kernel pool), copy vs page flip.

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
