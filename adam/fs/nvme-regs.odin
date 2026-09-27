package fs

import ah "../../asm_helpers"
import "../../lib/clock"


regCap: u32 : 0x00
regCc: u32 : 0x14
regCsts: u32 : 0x1C
regAqa: u32 : 0x24
regAsq: u32 : 0x28
regAcq: u32 : 0x30
regDoorbells: u32 : 0x1000


CAP :: bit_field u64 {
	mqes:       u16 | 16,
	cqr:        u8  | 1,
	ams:        u8  | 2,
	_:          u8  | 5,
	to:         u8  | 8,
	dstrd:      u8  | 4,
	nssrs:      u8  | 1,
	cssNcss:    u8  | 1,
	_:          u8  | 5,
	cssIocss:   u8  | 1,
	cssNoiocss: u8  | 1,
	bps:        u8  | 1,
	cps:        u8  | 2,
	mpsmin:     u8  | 4,
	mpsmax:     u8  | 4,
	pmrs:       u8  | 1,
	cmbs:       u8  | 1,
	nsss:       u8  | 1,
	crms:       u8  | 2,
	nsses:      u8  | 1,
	_:          u8  | 2,
}

CC :: bit_field u32 {
	en:     u8 | 1,
	_:      u8 | 3,
	css:    u8 | 3,
	mps:    u8 | 4,
	ams:    u8 | 3,
	shn:    u8 | 2,
	iosqes: u8 | 4,
	iocqes: u8 | 4,
	crime:  u8 | 1,
	_:      u8 | 7,
}

CSTS :: bit_field u32 {
	rdy:   u8  | 1,
	cfs:   u8  | 1,
	shst:  u8  | 2,
	nssro: u8  | 1,
	pp:    u8  | 1,
	st:    u8  | 1,
	_:     u32 | 25,
}

AQA :: bit_field u32 {
	asqs: u16 | 12,
	_:    u8  | 4,
	acqs: u16 | 12,
	_:    u8  | 4,
}

Controller :: struct {
	base: [^]u8,
}

read32 :: proc(c: Controller, offset: u32) -> u32 {
	assert(offset % 4 == 0)
	return ah.mmio_read_u32(&c.base[offset])
}
write32 :: proc(c: Controller, offset: u32, val: u32) {
	assert(offset % 4 == 0)
	ah.mmio_write_u32(&c.base[offset], val)
}
read64 :: proc(c: Controller, offset: u32) -> u64 {
	return u64(read32(c, offset)) | u64(read32(c, offset + 4)) << 32
}
write64 :: proc(c: Controller, offset: u32, val: u64) {
	write32(c, offset, u32(val))
	write32(c, offset + 4, u32(val >> 32))
}

read_cap :: proc(c: Controller) -> CAP {return transmute(CAP)read64(c, regCap)}
read_cc :: proc(c: Controller) -> CC {return transmute(CC)read32(c, regCc)}
write_cc :: proc(c: Controller, val: CC) {write32(c, regCc, transmute(u32)val)}
read_csts :: proc(c: Controller) -> CSTS {return transmute(CSTS)read32(c, regCsts)}
write_aqa :: proc(c: Controller, val: AQA) {write32(c, regAqa, transmute(u32)val)}

CAP_TIMEOUT_UNIT_MS :: u64(500)

ready_deadline :: proc(cap: CAP) -> u64 {
	assert(cap.to != 0)
	return clock.deadline_after_ms(u64(cap.to) * CAP_TIMEOUT_UNIT_MS)
}

doorbell_stride :: proc(cap: CAP) -> u32 {
	return u32(4) << cap.dstrd
}

doorbell :: proc(c: Controller, cap: CAP, qid: u16, isCompletion: bool) -> ^u32 {
	return (^u32)(
		&c.base[regDoorbells + (u32(qid) * 2 + u32(isCompletion)) * doorbell_stride(cap)],
	)
}
