package pe
import "../spinlock"

Bytecode :: struct {
	base:  u64,
	image: PeImage,
}

registry: struct {
	data: map[string]Bytecode,
	lock: spinlock.Spinlock,
}

load :: proc(data: []u8) -> (bc: Bytecode, ok: bool) {
	image, sections, parseErr := parse_pe(data)
	if parseErr != .None do return {}, false

	base, mapOk := pe_load_into_memory(&image, sections[:], data)
	if !mapOk do return {}, false

	return Bytecode{base = base, image = image}, true
}

store :: proc(name: string, bc: Bytecode) {
	spinlock.lock(&registry.lock)
	registry.data[name] = bc
	spinlock.unlock(&registry.lock)
}

get :: proc(name: string) -> (bc: Bytecode, found: bool) {
	spinlock.lock(&registry.lock)
	bc, found = registry.data[name]
	spinlock.unlock(&registry.lock)
	return
}

register :: proc(name: string, data: []u8) -> (bc: Bytecode, ok: bool) {
	bc = load(data) or_return
	store(name, bc)
	return bc, true
}

