package soabench

import "../lmem"
import "core:fmt"
import "core:testing"
import "core:time"

MemoryResourceFlag :: enum {
	Volatile,
	InterruptSource,
}

Resource :: struct {
	phys:          u64,
	logical:       u64,
	size:          u64,
	flags:         lmem.PageFlags,
	pageSize:      lmem.PageSize,
	resourceFlags: bit_set[MemoryResourceFlag;u8],
	contract:      rawptr,
	underlay:      rawptr,
}
#assert(size_of(Resource) == 56)

STRIDE :: 0x10000
SIZE :: 0x8000
VISITS_PER_RUN :: 1 << 26
SIZES :: [?]int{16, 64, 256, 1024, 4096, 16384, 65536}

aos_find :: proc(rs: []Resource, phys: u64) -> u64 {
	low, high := 0, len(rs)
	for low < high {
		mid := (low + high) / 2
		if rs[mid].phys <= phys do low = mid + 1
		else do high = mid
	}
	idx := low - 1
	if idx < 0 || phys - rs[idx].phys >= rs[idx].size do return 0
	if .Write not_in rs[idx].flags || .Volatile in rs[idx].resourceFlags do return 0
	return rs[idx].size
}

soa_find :: proc(rs: #soa[]Resource, phys: u64) -> u64 {
	low, high := 0, len(rs)
	for low < high {
		mid := (low + high) / 2
		if rs.phys[mid] <= phys do low = mid + 1
		else do high = mid
	}
	idx := low - 1
	if idx < 0 || phys - rs.phys[idx] >= rs.size[idx] do return 0
	if .Write not_in rs.flags[idx] || .Volatile in rs.resourceFlags[idx] do return 0
	return rs.size[idx]
}

aos_linear :: proc(rs: []Resource, phys: u64) -> u64 {
	for r in rs {
		if phys - r.phys < r.size {
			if .Write not_in r.flags || .Volatile in r.resourceFlags do return 0
			return r.size
		}
	}
	return 0
}

soa_linear :: proc(rs: #soa[]Resource, phys: u64) -> u64 {
	for i in 0 ..< len(rs) {
		if phys - rs.phys[i] < rs.size[i] {
			if .Write not_in rs.flags[i] || .Volatile in rs.resourceFlags[i] do return 0
			return rs.size[i]
		}
	}
	return 0
}

queries_make :: proc(n, count: int) -> []u64 {
	qs := make([]u64, count)
	x: u64 = 0x9E3779B97F4A7C15
	for &q in qs {
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		q = x % u64(n * STRIDE)
	}
	return qs
}

@(test)
bench :: proc(t: ^testing.T) {
	fmt.printfln("%-8s %-10s %10s %10s %10s %10s", "n", "bytes", "aos bin", "soa bin", "aos lin", "soa lin")
	for n in SIZES {
		aos := make([]Resource, n)
		defer delete(aos)
		soa := make(#soa[]Resource, n)
		defer delete(soa)
		for i in 0 ..< n {
			r := Resource {
				phys  = u64(i * STRIDE),
				size  = SIZE,
				flags = {.Present, .Write},
			}
			aos[i] = r
			soa[i] = r
		}

		binQs := queries_make(n, 1 << 22)
		defer delete(binQs)
		linQs := queries_make(n, max(64, VISITS_PER_RUN / n))
		defer delete(linQs)

		sink: u64
		ns: [4]f64
		for q in binQs do sink += aos_find(aos, q) + soa_find(soa, q)
		for q in linQs do sink += aos_linear(aos, q) + soa_linear(soa, q)

		start := time.tick_now()
		for q in binQs do sink += aos_find(aos, q)
		ns[0] = f64(time.tick_since(start)) / f64(len(binQs))

		start = time.tick_now()
		for q in binQs do sink += soa_find(soa, q)
		ns[1] = f64(time.tick_since(start)) / f64(len(binQs))

		start = time.tick_now()
		for q in linQs do sink += aos_linear(aos, q)
		ns[2] = f64(time.tick_since(start)) / f64(len(linQs))

		start = time.tick_now()
		for q in linQs do sink += soa_linear(soa, q)
		ns[3] = f64(time.tick_since(start)) / f64(len(linQs))

		testing.expect(t, sink != 0)
		fmt.printfln("%-8d %-10d %10.1f %10.1f %10.1f %10.1f", n, n * size_of(Resource), ns[0], ns[1], ns[2], ns[3])
	}
}
