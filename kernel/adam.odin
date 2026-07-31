package kernel
import "../asm_helpers"
import "../lib/elf"
import "../lib/shared"
import "base:intrinsics"
import "core:mem"
import "pmm"
import "print"
adam_init :: proc(adamImg: elf.Image) {

	assert((adamImg.end - adamImg.base) > 0)
	regions, mErr := make([]MemRegion, len(adamImg.segments))
	print.kensure(mErr == nil, "adam_init: process_spawn failed")

	for seg, i in adamImg.segments {
		flags := pmm.PageFlags{.Present, .User, .NX}
		if .X in seg.perms do flags -= {.NX}
		if .W in seg.perms do flags += {.Write}

		regions[i] = MemRegion {
			phys  = pmm.addr_round_down_to_page(seg.base),
			size  = pmm.addr_round_up_to_page(seg.end) - pmm.addr_round_down_to_page(seg.base),
			flags = flags,
		}
	}

	_, err := process_spawn(adamImg.entry, regions)
	print.kensure(err == nil, "adam_init: process_spawn failed")

}
