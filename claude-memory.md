# claude memory (terse)

## Work rules (user, 2026-10-26)
- Never invent limits or design and present them as fact. Facts: cite file:line or spec. Proposals: label them, the user decides.
- Context = files in the working tree only. Never read git history (deleted files) as context.
- Don't flip-flop. Pick one recommendation and keep it unless the user changes it.
- Print code only when asked. Write files only when explicitly asked.
- Teaching: user gets it from concrete line-by-line trace tables. Explain with traces.

## Errors (2026-10-27)
All syscall errors = shared.Error (SYSCALL range 0x400). Kernel and userland return shared.Error, use or_return.

## Locks
spinlock lock/unlock take `guards: [][]u8` (memory the lock guards). Same g for lock and unlock.
`g := [][]u8{mem.ptr_to_bytes(&x.a), mem.slice_to_bytes(arr[:])}; lock(&x.lock, g); defer unlock(&x.lock, g)`. Build g after any realloc.

## Contracts (in progress)
Design: contracts.md "CONTRACT" section. Work order: updates.md section 1.

Done:
- lib/syscalls/contracts.odin: ContractOp, ContractRule (16B #assert), ContractDesc, ContractAccessDir, CONTRACT_ACCESS_MAX, userspace wrappers.
- lib/syscalls/syscalls.asm: nr 7 (create), nr 8 (access), 4 args (rcx -> r10). Syscall enum + dispatch in kernel/syscall.odin.
- kernel/memory-resource.odin: MemoryResource.rContractRules, wContractRules.
- kernel/contracts.odin: syscall_contract_create, contract_rules_copy_in, contract_validate, contract_run_NO_LOCK
  (Load/Store64/Imm/Add/Sub/Shl/Shr/And/J*/HasPerm/Accept; Copy/List = unreachable), syscall_contract_memory_access
  (copy in before lock, caller read lock over find + run + device access, len 4/8 = one volatile op, copy out after lock).
- user_copy_out in kernel/protdomain-resources.odin.
- resource_contracted helper; grant refusal in prot_domain_create + edit Add; assert in resource_granted (regrant = refused).
- Edit Delete: frees rules, always releases underlay, skips unmap/tlb for flags {}. protdomain_free frees rules.
- pmm.map_kernel_mmio: BARs + pcie config pages mapped UC into kernel direct map in adam_init.
- Decision: replacing rules = Delete + Create, no in-place replace.

Open / next:
- Proposal (undecided): Volatile resource + len not 4/8 -> InvalidSize.
- contracts.md still says "caller owns with W"; now W only needed for wRules.
- Copy buffers design, pins, ring (tail replay / in-flight overwrite / unpin-during-DMA holes stay until then).
- ifs forged-slot problem at boot scan: undecided (option c = per-subtree ranges in adam config, a = reject overlaps).
