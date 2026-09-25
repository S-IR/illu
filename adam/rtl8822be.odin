package adam

import ah "../asm_helpers"
import "../lib/lmem"
import "../lib/pci"
import "../lib/syscalls"
import "core:mem"


@(rodata)
RTL8822B_FIRMWARE := #load("../firmware/rtw8822b_fw.bin", []u8)

RTL8822BE_VENDOR :: u16(0x10EC)
RTL8822BE_DEVICE :: u16(0xB822)

RTL_APS_FSMCO :: uintptr(0x0004) // power-sequence byte lanes live at +0..+3
RTL_SYS_CLK_CTRL :: uintptr(0x0008)
RTL_SYS_FUNC_EN :: uintptr(0x0002)
RTL_RSV_CTRL :: uintptr(0x001C)
RTL_RF_CTRL :: uintptr(0x001F)
RTL_RF_CTRL1 :: uintptr(0x0020)
RTL_AFE_CTRL1 :: uintptr(0x0024)
RTL_LED_CFG :: uintptr(0x004C)
RTL_GPIO_MUXCFG :: uintptr(0x0040)
RTL_HCI_OPT_CTRL :: uintptr(0x0074)
RTL_PAD_CTRL1 :: uintptr(0x0064)
RTL_MCUFW_CTRL :: uintptr(0x0080)
RTL_TXDMA_PQ_MAP :: uintptr(0x010C)
RTL_WLRF1 :: uintptr(0x00EC)
RTL_CR :: uintptr(0x0100)
RTL_RQPN_CTRL_2 :: uintptr(0x022C)
RTL_FIFOPAGE_1 :: uintptr(0x0230)
RTL_BCN_DESC :: uintptr(0x0308)
RTL_BCN_WORK :: uintptr(0x0383)
RTL_FIFOPAGE_CTRL2 :: uintptr(0x0204)
RTL_BCN_CTRL :: uintptr(0x0550)
RTL_FWHW_TXQ_CTRL :: uintptr(0x0420)
RTL_CPU_DMEM_CON :: uintptr(0x1080)
RTL_CR_EXT :: uintptr(0x1100)
RTL_DDMA_SA :: uintptr(0x1200)
RTL_DDMA_DA :: uintptr(0x1204)
RTL_DDMA_CTRL :: uintptr(0x1208)

RTL_FEN_CPUEN :: u8(1 << 2) // BIT_FEN_CPUEN, byte at REG_SYS_FUNC_EN+1
RTL_FEN_BB_ENABLE :: u8((1 << 1) | (1 << 0)) // BIT_FEN_BB_RSTB | BIT_FEN_BB_GLB_RST
RTL_WLMCU_IOIF :: u8(1 << 0) // BIT_WLMCU_IOIF, byte at REG_RSV_CTRL+1
RTL_RF_ENABLE :: u8(0x07) // BIT_RF_SDM_RSTB | BIT_RF_RSTB | BIT_RF_EN
RTL_CR_TXDMA :: u8((1 << 2) | (1 << 0))
RTL_CR_ENSWBCN :: u8(1 << 0) // BIT_ENSWBCN (bit 8 of REG_CR) as the byte at REG_CR+1
RTL_BCN_CTRL_DIS_TSF_UDT :: u8(1 << 4)
RTL_BCN_CTRL_EN_BCN_FUNCTION :: u8(1 << 3)
RTL_FWHW_TXQ_CTRL2_EN_BCNQ_DL :: u8(1 << 6) // BIT_EN_BCNQ_DL (bit 22) as the byte at REG_FWHW_TXQ_CTRL+2
RTL_FIFOPAGE_CTRL2_BCN_VALID :: u16(1 << 15)
RTL_BBRF_EN :: u32((1 << 24) | (1 << 25) | (1 << 26))
RTL_MAC_TRX_ENABLE :: u8(0xFF)
RTL_MCUFWDL_EN :: u16(1)
RTL_FW_READY :: u16(0xC078)
RTL_FW_READY_MASK :: u16(0xCFFF) // excludes the CPU_CLK_SEL bits (12:13)
RTL_DDMA_OWN :: u32(1 << 31)
RTL_DDMA_CHECKSUM_EN :: u32(1 << 29)
RTL_DDMA_CONT :: u32(1 << 24) // BIT_DDMACH0_CHKSUM_CONT: this is not the first chunk of the segment
RTL_DDMA_RESET_CHKSUM_STS :: u32(1 << 25) // one-shot: clear the sticky checksum-status bit before a segment
RTL_DDMA_STATUS :: u32(1 << 27) // BIT_DDMACH0_CHKSUM_STS
RTL_TXBUF_OCP :: u32(0x1878_0000)
RTL_DMEM_OCP :: u32(0x0020_0000)
RTL_IMEM_OCP :: u32(0x0003_0000)
RTL_FW_HDR_SIZE :: u64(64)
RTL_FW_CHECKSUM :: u64(8)
RTL_MCUFW_CTRL_IMEM_DW_OK :: u8(1 << 3)
RTL_MCUFW_CTRL_IMEM_CHKSUM_OK :: u8(1 << 4)
RTL_MCUFW_CTRL_DMEM_DW_OK :: u8(1 << 5)
RTL_MCUFW_CTRL_DMEM_CHKSUM_OK :: u8(1 << 6)

RTL8822BE_INIT_NO_BAR :: u64(1)
RTL8822BE_INIT_BAD_BAR :: u64(2)
RTL8822BE_INIT_NOT_READY :: u64(3)
RTL8822BE_INIT_REGISTER :: u64(4)

// rtl_rmw8 performs the read-modify-write pattern rtw88's power sequencing
// leans on throughout: clear `clear`, then set `set` (matching cmd->mask /
// cmd->value in struct rtw_pwr_seq_cmd, and rtw_write8_clr/_set elsewhere).
rtl_rmw8 :: proc(base, offset: uintptr, clear, set: u8) {
	ah.mmio_write_u8(
		rawptr(base + offset),
		(ah.mmio_read_u8(rawptr(base + offset)) & ~clear) | set,
	)
}

rtl_rmw32 :: proc(base, offset: uintptr, clear, set: u32) {
	ah.mmio_write_u32(
		rawptr(base + offset),
		(ah.mmio_read_u32(rawptr(base + offset)) & ~clear) | set,
	)
}

// rtl_poll8 waits (up to `iters` reads) for (reg & mask) == target, matching
// do_pwr_poll_cmd's role in rtw_pwr_seq_parser.
rtl_poll8 :: proc(base, offset: uintptr, mask, target: u8, iters: int) -> bool {
	for _ in 0 ..< iters {
		if ah.mmio_read_u8(rawptr(base + offset)) & mask == target do return true
		ah.cpu_pause()
	}
	return false
}

// rtl8822be_power_on runs rtw88's generic PCIe MAC bring-up in front of
// firmware download: rtw_mac_pre_system_cfg (park BB/RF/pin-mux in a known
// state), the card_enable_flow_8822b power-sequence table filtered to the
// PCIe/all-silicon-cut entries (trans_carddis_to_cardemu_8822b +
// trans_cardemu_to_act_8822b in rtw8822b.c), and rtw_mac_init_system_cfg
// (which is what actually clocks in the DDMA engine at 0x1200 -- without
// BIT_DDMA_EN the chip is unpowered and every register in that block reads
// back the fixed 0xEA sentinel rtw88 itself checks for "device off").
rtl8822be_power_on :: proc(base: uintptr) -> bool {
	// rtw_mac_pre_system_cfg (PCIe branch).
	rtl_rmw32(base, RTL_HCI_OPT_CTRL, 0, 1 << 8) // BIT_USB_SUS_DIS
	rtl_rmw32(base, RTL_PAD_CTRL1, 0, (1 << 29) | (1 << 28)) // BIT_PAPE_WLBT_SEL | BIT_LNAON_WLBT_SEL
	rtl_rmw32(base, RTL_LED_CFG, (1 << 26) | (1 << 25), 0) // ~(BIT_LNAON_SEL_EN | BIT_PAPE_SEL_EN)
	rtl_rmw32(base, RTL_GPIO_MUXCFG, 0, 1 << 2) // BIT_WLRFE_4_5_EN
	rtl_rmw8(base, RTL_SYS_FUNC_EN, RTL_FEN_BB_ENABLE, 0) // disable BB
	rtl_rmw8(base, RTL_RF_CTRL, RTL_RF_ENABLE, 0) // disable RF
	rtl_rmw32(base, RTL_WLRF1, RTL_BBRF_EN, 0)

	// card_disable -> card_emu (trans_carddis_to_cardemu_8822b, PCIe/ALL_MSK entries).
	rtl_rmw8(base, RTL_APS_FSMCO + 1, (1 << 3) | (1 << 4) | (1 << 7), 0)
	ah.mmio_write_u8(rawptr(base + 0x0300), 0)
	ah.mmio_write_u8(rawptr(base + 0x0301), 0)

	// card_emu -> active (trans_cardemu_to_act_8822b, PCIe/ALL_MSK entries).
	rtl_rmw8(base, RTL_APS_FSMCO + 0x0E, 1 << 1, 0)
	rtl_rmw8(base, RTL_APS_FSMCO + 0x0E, 1 << 0, 1 << 0)
	rtl_rmw8(base, RTL_APS_FSMCO + 1, (1 << 4) | (1 << 3) | (1 << 2), 0)
	rtl_rmw8(base, RTL_HCI_OPT_CTRL + 1, 1 << 0, 1 << 0) // 0x0075
	if !rtl_poll8(base, RTL_APS_FSMCO + 2, 1 << 1, 1 << 1, 10000) do return false // 0x0006
	rtl_rmw8(base, RTL_HCI_OPT_CTRL + 1, 1 << 0, 0) // 0x0075
	rtl_rmw8(base, RTL_APS_FSMCO + 2, 1 << 0, 1 << 0) // 0x0006
	rtl_rmw8(base, RTL_APS_FSMCO + 1, 1 << 7, 0)
	rtl_rmw8(base, RTL_APS_FSMCO + 1, (1 << 4) | (1 << 3), 0)
	rtl_rmw8(base, RTL_APS_FSMCO + 1, 1 << 0, 1 << 0)
	if !rtl_poll8(base, RTL_APS_FSMCO + 1, 1 << 0, 0, 10000) do return false
	rtl_rmw8(base, RTL_RF_CTRL1, 1 << 3, 1 << 3) // 0x0020
	rtl_rmw8(base, RTL_APS_FSMCO + 0x25, 0xFF, 0xF9) // 0x0029
	rtl_rmw8(base, RTL_AFE_CTRL1, 1 << 2, 0)
	rtl_rmw8(base, RTL_HCI_OPT_CTRL, 1 << 5, 1 << 5) // 0x0074
	rtl_rmw8(base, RTL_APS_FSMCO + 0xAB, 1 << 5, 1 << 5) // 0x00AF

	// rtw_mac_init_system_cfg.
	rtl_rmw32(base, RTL_CPU_DMEM_CON, 0, (1 << 16) | (1 << 8)) // BIT_WL_PLATFORM_RST | BIT_DDMA_EN
	rtl_rmw8(base, RTL_SYS_FUNC_EN + 1, 0, 0xDC) // chip->sys_func_en for 8822b
	rtl_rmw8(base, RTL_CR_EXT + 3, 0x0F, 0x0C)

	// rtw_mac_power_switch treats REG_CR == 0xEA as "the chip is not
	// powered" -- confirm the sequence above actually got the MAC clocked
	// before we go on to touch the DDMA/firmware-download registers, which
	// read back that exact sentinel when unpowered.
	assert(
		ah.mmio_read_u8(rawptr(base + RTL_CR)) != 0xEA,
		"MAC still unpowered after rtl8822be_power_on (REG_CR == 0xEA)",
	)
	assert(
		ah.mmio_read_u32(rawptr(base + RTL_CPU_DMEM_CON)) & (1 << 8) != 0,
		"BIT_DDMA_EN did not stick in REG_CPU_DMEM_CON",
	)

	return true
}

rtl8822be_init :: proc(device: ^pci.Device) -> (DriverResult, u64) {
	if device == nil do return .Failed, RTL8822BE_INIT_NOT_READY
	if device.vendorId != RTL8822BE_VENDOR || device.deviceId != RTL8822BE_DEVICE {
		return .Ignored, 0
	}

	// rtw88's PCIe HCI layer always maps BAR2 for the CSR/MMIO space
	// (rtw_pci_io_mapping, bar_id = 2) -- BAR0/BAR1 are the legacy I/O and a
	// small config window, not the register file this driver programs.
	bar := device.bars[2]
	if bar.addr == 0 || bar.size == 0 || !bar.isMemory do return .Failed, RTL8822BE_INIT_NO_BAR
	// Every register this driver touches, including the DDMA block at
	// 0x1200-0x1208, must fall inside the mapped BAR or we're programming
	// whatever happens to sit past the end of the MMIO window.
	assert(bar.size >= 0x1300, "BAR2 too small to cover the registers this driver programs")

	// Adam's protection domain identity-maps PCI MMIO BARs before entering
	// this code, so BAR0 can be used directly as an MMIO virtual address.
	command := pci.config_read_u16(device, pci.CONFIG_COMMAND_OFFSET)
	command |= pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER
	pci.config_write_u16(device, pci.CONFIG_COMMAND_OFFSET, command)
	assert(
		pci.config_read_u16(device, pci.CONFIG_COMMAND_OFFSET) &
			(pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER) ==
		pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER,
		"PCI command register didn't latch MEMORY|BUS_MASTER",
	)

	base := uintptr(bar.addr)

	// Power the MAC on (rtw_mac_power_on): without this the chip is
	// literally unclocked and every register -- including the DDMA engine
	// firmware download depends on -- reads back the fixed 0xEA "off"
	// sentinel. BB/RF stay disabled here; rtw8822b_phy_set_param only turns
	// them on after firmware has been downloaded, below.
	if !rtl8822be_power_on(base) do return .Failed, RTL8822BE_INIT_NOT_READY

	// wlan_cpu_enable(false): hold the MCU's IO interface and CPU enable
	// bit down while we push firmware bytes into its memory.
	rtl_rmw8(base, RTL_RSV_CTRL + 1, RTL_WLMCU_IOIF, 0)
	rtl_rmw8(base, RTL_SYS_FUNC_EN + 1, RTL_FEN_CPUEN, 0)

	{
		// The rtw88 PCIe path sends each firmware block through the beacon
		// descriptor, then copies it from the device TX FIFO with DDMA.
		if u64(len(RTL8822B_FIRMWARE)) < RTL_FW_HDR_SIZE do return .Failed, 5
		le32 := proc(p: []u8) -> u32 {return(
				u32(p[0]) |
				u32(p[1]) << 8 |
				u32(p[2]) << 16 |
				u32(p[3]) << 24 \
			)}
		dmemSize := u64(le32(RTL8822B_FIRMWARE[0x24:0x28])) + RTL_FW_CHECKSUM
		imemSize := u64(le32(RTL8822B_FIRMWARE[0x30:0x34])) + RTL_FW_CHECKSUM
		ememSize := u64(0)
		if RTL8822B_FIRMWARE[0x18] & 0x10 != 0 do ememSize = u64(le32(RTL8822B_FIRMWARE[0x34:0x38])) + RTL_FW_CHECKSUM
		if RTL_FW_HDR_SIZE + dmemSize + imemSize + ememSize != u64(len(RTL8822B_FIRMWARE)) {
			return .Failed, 6
		}
		if dmemSize > 0x3FFFF || imemSize > 0x3FFFF || ememSize > 0x3FFFF do return .Failed, 7

		syscalls.syscall_debug_print_userspace(
			"firmware blob length",
			u64(len(RTL8822B_FIRMWARE)),
		)
		syscalls.syscall_debug_print_userspace(
			"firmware mem_usage byte",
			u64(RTL8822B_FIRMWARE[0x18]),
		)
		syscalls.syscall_debug_print_userspace(
			"firmware dmem_addr (raw, w/ valid bit)",
			u64(le32(RTL8822B_FIRMWARE[0x20:0x24])),
		)
		syscalls.syscall_debug_print_userspace("firmware dmemSize", dmemSize)
		syscalls.syscall_debug_print_userspace(
			"firmware imem_addr (raw, w/ valid bit)",
			u64(le32(RTL8822B_FIRMWARE[0x3C:0x40])),
		)
		syscalls.syscall_debug_print_userspace("firmware imemSize", imemSize)
		syscalls.syscall_debug_print_userspace("firmware ememSize", ememSize)
		// Realtek firmware regions are built so the region's data plus
		// its trailing checksum word sum to zero (classic internet-style
		// ones-complement checksum). Verify our own read of the dmem
		// region bytes actually satisfies that before blaming the DMA
		// path for a mismatch.
		dmemSum: u32 = 0
		for i := u64(0); i < dmemSize; i += 2 {
			dmemSum +=
				u32(RTL8822B_FIRMWARE[RTL_FW_HDR_SIZE + i]) |
				u32(RTL8822B_FIRMWARE[RTL_FW_HDR_SIZE + i + 1]) << 8
		}
		for dmemSum > 0xFFFF do dmemSum = (dmemSum & 0xFFFF) + (dmemSum >> 16)
		syscalls.syscall_debug_print_userspace(
			"folded 16-bit sum over dmem region (0 if checksum theory holds)",
			u64(dmemSum),
		)

		pages := (u64(len(RTL8822B_FIRMWARE)) + 0xFFF) / 0x1000
		regions := [1]syscalls.MMapRegion {
			{pageSize = lmem.PageSize._4KB, count = pages + 2, flags = {.Present, .Write}},
		}
		mmapErr, dma := syscalls.syscall_mmap_userspace(regions[:])
		if mmapErr != .None || dma == nil || u64(uintptr(dma)) > u64(max(u32)) do return .Failed, 8
		defer syscalls.syscall_mfree_userspace([]u64{u64(uintptr(dma))})
		mem.copy(dma, rawptr(&RTL8822B_FIRMWARE[0]), len(RTL8822B_FIRMWARE))
		uploadDesc := rawptr(uintptr(dma) + uintptr(pages * 0x1000))
		mem.zero(uploadDesc, 0x1000)
		// The per-chunk packet buffer (48-byte TX descriptor + up to 4KB of
		// payload) lives 64 bytes into the page right after uploadDesc, and
		// the mmap above reserved exactly 2 pages past the firmware image
		// for this pair -- confirm a full-size chunk can never spill past
		// what's actually mapped.
		assert(64 + 0x1000 <= 2 * 0x1000, "packet scratch layout overflows its reserved pages")
		// One beacon descriptor and one TX packet descriptor are sufficient for
		// the serialized download; the descriptor is reused after each DDMA copy.
		ah.mmio_write_u32(rawptr(base + RTL_BCN_DESC), u32(uintptr(uploadDesc)))
		ah.mmio_write_u8(rawptr(base + RTL_CR), RTL_CR_TXDMA)
		// download_firmware_reg_backup only ever ORs in BIT_LD_RQPN here to
		// reload whatever page table is already loaded -- on this chip
		// family RQPN_CTRL_2 doesn't carry page-count fields at all (those
		// live in REG_FIFOPAGE_INFO_1..5, set up by priority_queue_cfg,
		// which runs later during rtw_mac_init). Packing invented 0x20/0xE0
		// sub-fields in here reprogrammed the page table to bogus values,
		// which is why the BCN queue's page landed somewhere other than
		// TXBUF_OCP+0 and the DDMA checksum kept failing.
		rtl_rmw32(base, RTL_RQPN_CTRL_2, 0, 1 << 31)
		ah.mmio_write_u16(rawptr(base + RTL_FIFOPAGE_1), 0x200)
		ah.mmio_write_u16(
			rawptr(base + RTL_MCUFW_CTRL),
			ah.mmio_read_u16(rawptr(base + RTL_MCUFW_CTRL)) & 0x3800 | RTL_MCUFWDL_EN,
		)
		assert(
			ah.mmio_read_u16(rawptr(base + RTL_MCUFW_CTRL)) & RTL_MCUFWDL_EN != 0,
			"BIT_MCUFWDL_EN did not stick in REG_MCUFW_CTRL",
		)

		// rtw_fw_write_data_rsvd_page reads these once (they don't change
		// out from under us between calls) but re-applies and restores them
		// around *every single* reserved-page write -- confirmed against a
		// live mmiotrace of the stock driver downloading this exact
		// firmware: REG_FIFOPAGE_CTRL_2/REG_CR+1/REG_BCN_CTRL/
		// REG_FWHW_TXQ_CTRL+2 toggle on every chunk, not once for the whole
		// download. BIT_BCN_VALID_V1 in particular looks edge-triggered:
		// holding it "valid" for multiple chunks in a row means only the
		// first chunk's payload actually lands in TXBUF_OCP, which the DDMA
		// engine will happily keep re-copying (OWN clears fine) while the
		// checksum on later chunks fails against stale data -- exactly the
		// symptom this was causing.
		bcnCtrlBackup := ah.mmio_read_u8(rawptr(base + RTL_BCN_CTRL))
		crHiBackup := ah.mmio_read_u8(rawptr(base + RTL_CR + 1))
		fwhwTxqCtrl2Backup := ah.mmio_read_u8(rawptr(base + RTL_FWHW_TXQ_CTRL + 2))

		for segment in 0 ..< 3 {
			size: u64
			dst: u32
			off: u64
			switch segment {
			case 0:
				size, dst, off =
					dmemSize, le32(RTL8822B_FIRMWARE[0x20:0x24]) & ~u32(1 << 31), RTL_FW_HDR_SIZE
			case 1:
				size, dst, off =
					imemSize,
					le32(RTL8822B_FIRMWARE[0x3C:0x40]) &
					~u32(1 << 31),
					RTL_FW_HDR_SIZE +
					dmemSize
			case 2:
				if ememSize == 0 do continue
				size, dst, off =
					ememSize,
					le32(RTL8822B_FIRMWARE[0x38:0x3C]) &
					~u32(1 << 31),
					RTL_FW_HDR_SIZE +
					dmemSize +
					imemSize
			}
			if u64(dst) + size > u64(max(u32)) do return .Failed, 9
			// download_firmware_to_mem: clear the DDMA engine's sticky
			// checksum-status bit once before this segment's chunks, rather
			// than folding it into the per-chunk transfer control word.
			rtl_rmw32(base, RTL_DDMA_CTRL, 0, RTL_DDMA_RESET_CHKSUM_STS)
			syscalls.syscall_debug_print_userspace(
				"segment index (0=dmem,1=imem,2=emem)",
				u64(segment),
			)
			syscalls.syscall_debug_print_userspace("segment size", size)
			syscalls.syscall_debug_print_userspace("segment dest OCP addr", u64(dst))
			for done: u64 = 0; done < size; {
				chunk := min(u64(0x1000), size - done)
				packet := uintptr(dma) + uintptr(pages * 0x1000) + 16 + 48
				mem.copy(rawptr(packet), rawptr(uintptr(dma) + uintptr(off + done)), int(chunk))
				// 8822B TX descriptor: 48-byte descriptor, beacon queue, last
				// segment. The checksum covers the first 32 descriptor bytes.
				// w1 also carries RATE_ID (RTW_RATEID_B_20M=8) and w3/w4 a
				// forced fixed rate (USE_RATE, DISDATAFB, DESC_RATE1M=0) --
				// rtw_tx_pkt_info_update_rate sets these unconditionally for
				// every reserved-page write, not just real data frames.
				(^u32)(rawptr(packet - 48))^ =
					u32(chunk) | u32(48 << 16) | u32(1 << 26) | u32(1 << 31)
				(^u32)(rawptr(packet - 44))^ = u32(16 << 8) | u32(8 << 16)
				(^u32)(rawptr(packet - 40))^ = 0
				(^u32)(rawptr(packet - 36))^ = u32(1 << 8) | u32(1 << 10)
				(^u32)(rawptr(packet - 32))^ = 0
				(^u32)(rawptr(packet - 28))^ = 0
				(^u32)(rawptr(packet - 24))^ = 0
				(^u32)(rawptr(packet - 20))^ = 0
				(^u32)(rawptr(packet - 16))^ = u32(1 << 15)
				(^u32)(rawptr(packet - 12))^ = 0
				checksum: u16 = 0
				for word in 0 ..< 16 {checksum = checksum ~ ((^u16)(rawptr(packet - 48 + uintptr(word * 2)))^)}
				(^u16)(rawptr(packet - 20))^ = checksum
				syscalls.syscall_debug_print_userspace("chunk size", u64(chunk))
				syscalls.syscall_debug_print_userspace("tx-desc checksum", u64(checksum))
				// rtw_fw_write_data_rsvd_page, run fresh for every chunk: mark
				// the (reused, pg_addr=0) page valid, switch the beacon to
				// software control, stop the beacon function so it doesn't
				// contend for the queue, and (PCIe only) disable auto
				// beacon-queue download so our BD write below is what the
				// hardware actually consumes.
				ah.mmio_write_u16(rawptr(base + RTL_FIFOPAGE_CTRL2), RTL_FIFOPAGE_CTRL2_BCN_VALID)
				ah.mmio_write_u8(rawptr(base + RTL_CR + 1), crHiBackup | RTL_CR_ENSWBCN)
				ah.mmio_write_u8(
					rawptr(base + RTL_BCN_CTRL),
					(bcnCtrlBackup & ~RTL_BCN_CTRL_EN_BCN_FUNCTION) | RTL_BCN_CTRL_DIS_TSF_UDT,
				)
				ah.mmio_write_u8(
					rawptr(base + RTL_FWHW_TXQ_CTRL + 2),
					fwhwTxqCtrl2Backup & ~RTL_FWHW_TXQ_CTRL2_EN_BCNQ_DL,
				)
				// PCIe TX buffer-descriptor ring entry for the beacon queue: two
				// 8-byte sub-entries (buf_size, psb_len/reserved, dma) describing
				// the 48-byte TX packet descriptor and the payload that follows
				// it, matching struct rtw_pci_tx_buffer_desc[2] in rtw88.
				ah.mmio_write_u16(rawptr(uintptr(uploadDesc)), u16(48))
				ah.mmio_write_u16(
					rawptr(uintptr(uploadDesc) + 2),
					u16(((48 + chunk + 127) / 128) | (1 << 15)),
				)
				ah.mmio_write_u32(rawptr(uintptr(uploadDesc) + 4), u32(packet - 48))
				ah.mmio_write_u16(rawptr(uintptr(uploadDesc) + 8), u16(chunk))
				ah.mmio_write_u16(rawptr(uintptr(uploadDesc) + 10), 0)
				ah.mmio_write_u32(rawptr(uintptr(uploadDesc) + 12), u32(packet))
				ah.mmio_write_u8(
					rawptr(base + RTL_BCN_WORK),
					ah.mmio_read_u8(rawptr(base + RTL_BCN_WORK)) | u8(1 << 4),
				)
				// RTL_BCN_WORK is a fire-and-forget doorbell, not a status
				// flag; wait for the hardware to latch the reserved page
				// instead (REG_FIFOPAGE_CTRL_2 / BIT_BCN_VALID_V1).
				ready := false
				fifopageVal: u16
				for _ in 0 ..< 10000 {
					fifopageVal = ah.mmio_read_u16(rawptr(base + RTL_FIFOPAGE_CTRL2))
					if fifopageVal & RTL_FIFOPAGE_CTRL2_BCN_VALID != 0 {
						ready = true
						break
					}
					ah.cpu_pause()
				}
				assert(
					ready,
					"beacon reserved-page write never latched (FIFOPAGE_CTRL_2 BCN_VALID)",
				)
				if !ready do return .Failed, 10
				// Restore: matches rtw_fw_write_data_rsvd_page's tail end,
				// run every chunk (not just once at the end of the whole
				// download) so the next chunk's mark-valid above is a
				// genuine low->high transition.
				ah.mmio_write_u16(rawptr(base + RTL_FIFOPAGE_CTRL2), RTL_FIFOPAGE_CTRL2_BCN_VALID)
				ah.mmio_write_u8(rawptr(base + RTL_BCN_CTRL), bcnCtrlBackup)
				ah.mmio_write_u8(rawptr(base + RTL_FWHW_TXQ_CTRL + 2), fwhwTxqCtrl2Backup)
				ah.mmio_write_u8(rawptr(base + RTL_CR + 1), crHiBackup)
				ctrl :=
					RTL_DDMA_OWN |
					RTL_DDMA_CHECKSUM_EN |
					(0 if done == 0 else RTL_DDMA_CONT) |
					u32(chunk)
				ah.mmio_write_u32(rawptr(base + RTL_DDMA_SA), RTL_TXBUF_OCP + 48)
				ah.mmio_write_u32(rawptr(base + RTL_DDMA_DA), dst + u32(done))
				ah.mmio_write_u32(rawptr(base + RTL_DDMA_CTRL), ctrl)
				// download_firmware_to_mem never inspects CHKSUM_STS per
				// chunk -- it's a running checksum across the whole segment
				// that only settles once the final chunk (carrying the
				// segment's trailing checksum bytes) has gone through.
				// OWN is the only thing worth polling per chunk; the
				// segment-level check below is what actually validates it.
				ownCleared := false
				for _ in 0 ..< 10000 {
					if ah.mmio_read_u32(rawptr(base + RTL_DDMA_CTRL)) & RTL_DDMA_OWN == 0 {
						ownCleared = true
						break
					}
					ah.cpu_pause()
				}
				assert(ownCleared, "DDMA chunk transfer never completed (OWN stuck)")
				if !ownCleared do return .Failed, 11
				done += chunk
			}
			// check_fw_checksum: the DDMA engine only latches a sticky status
			// bit per segment, not per chunk -- the driver is what records
			// DW_OK/CHECKSUM_OK into REG_MCUFW_CTRL, which is what the
			// FW_READY poll below is actually waiting on.
			segFailed := ah.mmio_read_u32(rawptr(base + RTL_DDMA_CTRL)) & RTL_DDMA_STATUS != 0
			isImem := dst < RTL_DMEM_OCP
			dwOkBit := RTL_MCUFW_CTRL_IMEM_DW_OK if isImem else RTL_MCUFW_CTRL_DMEM_DW_OK
			chkOkBit := RTL_MCUFW_CTRL_IMEM_CHKSUM_OK if isImem else RTL_MCUFW_CTRL_DMEM_CHKSUM_OK
			if segFailed {
				rtl_rmw8(base, RTL_MCUFW_CTRL, chkOkBit, dwOkBit)
				return .Failed, 11
			}
			rtl_rmw8(base, RTL_MCUFW_CTRL, 0, dwOkBit | chkOkBit)
		}
		ah.mmio_write_u16(
			rawptr(base + RTL_MCUFW_CTRL),
			(ah.mmio_read_u16(rawptr(base + RTL_MCUFW_CTRL)) | u16(1 << 14)) & ~RTL_MCUFWDL_EN,
		)
		// wlan_cpu_enable(true) has to happen *before* polling FW_READY, not
		// after -- confirmed against the live mmiotrace: BIT_FW_INIT_RDY
		// (bit 15 of FW_READY) is set by the firmware itself once it starts
		// executing, which obviously can't happen while BIT_FEN_CPUEN still
		// holds the MCU's clock/fetch disabled.
		rtl_rmw8(base, RTL_RSV_CTRL + 1, 0, RTL_WLMCU_IOIF)
		rtl_rmw8(base, RTL_SYS_FUNC_EN + 1, 0, RTL_FEN_CPUEN)
		for _ in 0 ..< 10000 {if ah.mmio_read_u16(rawptr(base + RTL_MCUFW_CTRL)) & RTL_FW_READY_MASK == RTL_FW_READY do break; ah.cpu_pause()}
		fwReady :=
			ah.mmio_read_u16(rawptr(base + RTL_MCUFW_CTRL)) & RTL_FW_READY_MASK == RTL_FW_READY
		assert(
			fwReady,
			"firmware never reached FW_READY (IMEM/DMEM download+checksum bits never all set)",
		)
		if !fwReady do return .Failed, 12

		// rtw8822b_phy_set_param: power on the BB/RF domain now that firmware
		// is running -- deliberately not done any earlier
		// (rtw_mac_pre_system_cfg holds it disabled until now).
		rtl_rmw8(base, RTL_SYS_FUNC_EN, 0, RTL_FEN_BB_ENABLE)
		rtl_rmw8(base, RTL_RF_CTRL, 0, RTL_RF_ENABLE)
		ah.mmio_write_u32(
			rawptr(base + RTL_WLRF1),
			ah.mmio_read_u32(rawptr(base + RTL_WLRF1)) | RTL_BBRF_EN,
		)
		if ah.mmio_read_u32(rawptr(base + RTL_WLRF1)) & RTL_BBRF_EN != RTL_BBRF_EN do return .Failed, 13
		ah.mmio_write_u8(rawptr(base + RTL_CR), 0)
		ah.mmio_write_u8(rawptr(base + RTL_CR), RTL_MAC_TRX_ENABLE)
		trxEnabled := ah.mmio_read_u8(rawptr(base + RTL_CR)) == RTL_MAC_TRX_ENABLE
		assert(trxEnabled, "REG_CR didn't hold MAC_TRX_ENABLE after enabling TX/RX DMA")
		if !trxEnabled do return .Failed, 14
	}
	state := RTL8822BE_State {
		bar        = bar,
		mmio       = bar.addr,
		txDma      = nil,
		txDmaPhys  = 0,
		txSlotSize = 0,
		txSlots    = 0,
		txHead     = 0,
		txLock     = {},
		rxDma      = nil,
		rxDmaPhys  = 0,
		rxSlotSize = 0,
		rxSlots    = 0,
		rxHead     = 0,
		rxTail     = 0,
		rxLock     = {},
	}
	registerErr := wifi_register(WifiDevice{bar = bar, impl = state})
	if registerErr != nil do return .Failed, RTL8822BE_INIT_REGISTER
	return .Initialized, 0
}
