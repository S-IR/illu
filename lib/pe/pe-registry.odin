package pe
import "../spinlock"
import "core:mem"

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
	registryGuards := [][]u8{mem.ptr_to_bytes(&registry)}
	spinlock.lock(&registry.lock, registryGuards)
	registry.data[name] = bc
	spinlock.unlock(&registry.lock, registryGuards)
}

get :: proc(name: string) -> (bc: Bytecode, found: bool) {
	registryGuards := [][]u8{mem.ptr_to_bytes(&registry)}
	spinlock.lock(&registry.lock, registryGuards)
	bc, found = registry.data[name]
	spinlock.unlock(&registry.lock, registryGuards)
	return
}

register :: proc(name: string, data: []u8) -> (bc: Bytecode, ok: bool) {
	bc = load(data) or_return
	store(name, bc)
	return bc, true
}

