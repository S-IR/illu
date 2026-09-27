package nvme


NVM_FLUSH :: u8(0x00)
NVM_WRITE :: u8(0x01)
NVM_READ :: u8(0x02)

CDW0 :: bit_field u32 {
	opc:  u8  | 8,
	fuse: u8  | 2,
	_:    u8  | 4,
	psdt: u8  | 2,
	cid:  u16 | 16,
}

SQE :: struct #packed {
	cdw0:  CDW0,
	nsid:  u32,
	cdw2:  u32,
	cdw3:  u32,
	mptr:  u64,
	prp1:  u64,
	prp2:  u64,
	cdw10: u32,
	cdw11: u32,
	cdw12: u32,
	cdw13: u32,
	cdw14: u32,
	cdw15: u32,
}
#assert(size_of(SQE) == 64)
#assert(offset_of(SQE, prp1) == 24)
#assert(offset_of(SQE, cdw10) == 40)

CQE_DW2 :: bit_field u32 {
	sqhd: u16 | 16,
	sqid: u16 | 16,
}

CQE_DW3 :: bit_field u32 {
	cid: u16 | 16,
	p:   u8  | 1,
	sc:  u8  | 8,
	sct: u8  | 3,
	crd: u8  | 2,
	m:   u8  | 1,
	dnr: u8  | 1,
}

CQE :: struct #packed {
	dw0: u32,
	dw1: u32,
	dw2: CQE_DW2,
	dw3: CQE_DW3,
}
#assert(size_of(CQE) == 16)
#assert(offset_of(CQE, dw3) == 12)

cqe_ok :: proc(cqe: CQE) -> bool {
	return cqe.dw3.sc == 0 && cqe.dw3.sct == 0
}

QueueInfo :: struct {
	sq:         [^]SQE,
	cq:         [^]CQE,
	sqDoorbell: ^u32,
	cqDoorbell: ^u32,
	depth:      u32,
	qid:        u16,
	nsid:       u32,
	lbaSize:    u32,
}
