---

1. lib/syscalls/syscalls.odin — new descriptor struct

odin
MMapRegion :: struct #packed {
pageSize: lmem.PageSize,
count: u64,
flags: lmem.PageFlags,
}

2. lib/syscalls/syscalls.odin — raw foreign decl

Replace:
odin
syscall_mmap :: proc(count: u64, size: u64, flagsPtr: u64) -> (err: u64, addr: u64) ---
with:
odin
syscall_mmap :: proc(regionsPtr: u64, regionCount: u64) -> (err: u64, addr: u64) ---

3. lib/syscalls/syscalls.odin — syscall_mmap_userspace rewritten to the new shape

Replace the existing wrapper with:
odin
syscall_mmap_userspace :: proc "contextless" (
regions: []MMapRegion,
) -> (
err: MMapError,
addr: rawptr,
) {
if len(regions) == 0 do return .InvalidSize, nil
rawErr, rawAddr := syscall_mmap(u64(uintptr(raw_data(regions))), u
return MMapError(rawErr), rawptr(uintptr(rawAddr))
}

4. kernel/syscall.odin — dispatch case, now just forwards ptr+count like ProtDomainCreate does

odin
case .MMap:
mmapErr, addr := syscall_mmap(a1, a2)
return u64(mmapErr), addr
(delete the old count/a2 >= len(lmem.PageSize)/pageFlags block above it)

5. kernel/syscall.odin — a small helper, since page-byte-size is now needed per descriptor in a loop instead of once

odin
mmap_page_size_bytes :: proc "contextless" (size: lmem.PageSize) -> u64 {
switch size {
case ._4KB:
return 4 * mem.Kilobyte
case ._2MB:
return 2 * mem.Megabyte
case ._1GB:
return mem.Gigabyte
}
return 0
}

6. kernel/syscall.odin — syscall_mmap itself, full rewrite

odin
syscall_mmap :: proc "contextless" (
regionsPtr, regionCount: u64,
) -> (
err: syscalls.MMapError,
phys: u64,
) {
context = gKernelCtx
if regionCount == 0 do return .InvalidSize, 0

      cpu := gs_read_cpustate()
      if cpu == nil || cpu.rrCurrent == nil || cpu.rrCurrent.domain == nil {
              return .InvalidSize, 0
      }
      domain := cpu.rrCurrent.domain

      regionsBytes, overflowed := intrinsics.overflow_mul(regionCount, s
      if overflowed do return .InvalidSize, 0
      if !pmm.user_range_accessible(domain.pml4, regionsPtr, regionsBytes, write = false) {
              return .InvalidSize, 0
      }
      regions := mem.slice_ptr((^syscalls.MMapRegion)(rawptr(uintptr(reg

      totalBytes: u64
      for r in regions {
              if r.count == 0 do return .InvalidSize, 0
              pageBytes := mmap_page_size_bytes(r.pageSize)
              if pageBytes == 0 do return .InvalidPageSize, 0
              rBytes, ov1 := intrinsics.overflow_mul(r.count, pageBytes)
              if ov1 do return .InvalidSize, 0
              newTotal, ov2 := intrinsics.overflow_add(totalBytes, rBytes)
              if ov2 do return .InvalidSize, 0
              totalBytes = newTotal
      }
      if totalBytes == 0 do return .InvalidSize, 0

      allocatedPhys := uintptr(pmm.alloc_zeroed(totalBytes))
      if allocatedPhys == 0 || allocatedPhys == max(uintptr) do return .OutOfMemory, 0

      offset: u64 = 0
      failedIdx := -1
      for r, idx in regions {
              pageBytes := mmap_page_size_bytes(r.pageSize)
              rBytes := r.count * pageBytes
              regionPhys := u64(allocatedPhys) + offset

              mapFlags := r.flags
              mapFlags -= {.Present, .PS}
              mapFlags += {.User}

              for i in u64(0) ..< r.count {
                      pmm.map_page(domain.pml4, regionPhys + i * pageByts, r.pageSize, mapFlags)
              }

              resource: MemoryResource
              memory_resource_init(&resource, regionPhys, rBytes, r.pageSize, mapFlags, {}, .AllocatedRAM)

              ok: bool
              {
                      spinlock.rw_write_lock(&domain.lock)
                      defer spinlock.rw_write_unlock(&domain.lock)
                      _, ok = resource_insert(&domain.resources, resource)
              }
              if !ok {
                      failedIdx = idx
                      break
              }

              offset += rBytes
      }

      if failedIdx >= 0 {
              {
                      spinlock.rw_write_lock(&domain.lock)
                      defer spinlock.rw_write_unlock(&domain.lock)
                      off: u64 = 0
                      for i in 0 ..< failedIdx {
                              resource_remove(&domain.resources, u64(all
                              off += regions[i].count * mmap_page_size_bytes(regions[i].pageSize)
                      }
              }
              off: u64 = 0
              for i in 0 ..= failedIdx {
                      r := regions[i]
                      pageBytes := mmap_page_size_bytes(r.pageSize)
                      regionPhys := u64(allocatedPhys) + off
                      for j in u64(0) ..< r.count {
                              pmm.unmap_page(domain.pml4, regionPhys + j
                      }
                      off += r.count * pageBytes
              }
              pmm.free_pages(u64(allocatedPhys), totalBytes)
              return .TrackingFailed, 0
      }

      return .None, u64(allocatedPhys)

}

Note: I dropped the old debug pte-printing block (if .Write in flags { ... print.serial_write("mmap ptes ")... }) — it only made sense for a single uniform region and doesn't
generalize to per-descriptor flags. Flag if you want it kept in some for

Each descriptor becomes its own MemoryResource (own phys start, own pageomainEdit on a sub-region's own returned offset still works exactly liketoday, one resource at a time. Rollback on a mid-array failure unmaps+frees everything, including the failed descriptor's already-mapped (but not yet tracked) pages.

7. lib/alloc/backend.odin — update the one call site

odin
when KERNEL_BUILD {
return pmm.alloc_pages(count * u64(shared.PAGE_SIZE))
} else {
regions := [1]syscalls.MMapRegion {
{pageSize = lmem.PageSize._4KB, count = count, fla
}
err, addr := syscalls.syscall_mmap_userspace(regions[:])
if err != .None || addr == nil {
return max(u64)
}
return u64(uintptr(addr))
}

8. adam/rtl8822be.odin — update the one call site

odin
pages := (u64(len(RTL8822B_FIRMWARE)) + 0xFFF) / 0x1000
regions := [1]syscalls.MMapRegion {
{pageSize = lmem.PageSize._4KB, count = pages + 2,
}
mmapErr, dma := syscalls.syscall_mmap_userspace(regions[:]
(rest of that block unchanged)

9. adam/main.odin — cosmetic only

Lines 13/15 are commented-out calls (syscalls.syscall_mmap_userspace(2, lmem.PageSize._4KB, {.Present, .Write})). Dead code, doesn't need to compile, but if you want them left as valid reference for later they'd become syscalls.syscall_mmap_usn{{pageSize = lmem.PageSize._4KB, count = 2, flags = {.Present,.Write}}}[:]). Your call whether to bother.
