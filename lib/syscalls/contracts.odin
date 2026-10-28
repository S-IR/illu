package syscalls
import "../shared"

CONTRACT_ACCESS_MAX :: 64
ContractOp :: enum u8 {
	Load8,
	Load16,
	Load32,
	Load64,
	Store64,
	Imm,
	Add,
	Sub,
	Shl,
	Shr,
	And,
	Jeq,
	Jne,
	Jlt,
	Jge,
	Accept,
	HasPermR,
	HasPermW,
	Copy,
	ListR,
	ListW,
}

ContractRule :: struct {
	imm:  u64,
	op:   ContractOp,
	a, b: u8,
}
#assert(size_of(ContractRule) == 16)

ContractDesc :: struct {
	rPtr, rCount, wPtr, wCount: u64,
}
ContractAccessDir :: enum u64 {
	Read,
	Write,
}

when !ODIN_TEST {
	when !KERNEL_BUILD {
		syscall_contract_create_userspace :: proc "contextless" (
			handle: int,
			phys, size: u64,
			rRules, wRules: []ContractRule,
		) -> (
			err: shared.Error,
		) {
			desc := ContractDesc {
				rPtr   = u64(uintptr(raw_data(rRules))),
				rCount = u64(len(rRules)),
				wPtr   = u64(uintptr(raw_data(wRules))),
				wCount = u64(len(wRules)),
			}
			return shared.Error(
				syscall_contract_create(transmute(u64)handle, phys, size, u64(uintptr(&desc))),
			)
		}

		syscall_contract_memory_access_userspace :: proc "contextless" (
			dst: u64,
			buf: []u8,
			dir: ContractAccessDir,
		) -> (
			err: shared.Error,
		) {
			return shared.Error(
				syscall_contract_memory_access(
					dst,
					u64(uintptr(raw_data(buf))),
					u64(len(buf)),
					u64(dir),
				),
			)
		}
	}
}
