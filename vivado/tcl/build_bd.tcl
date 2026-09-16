# build_bd.tcl  --  KV260 IMX477 raw-CSI capture design, Vivado 2024.1
# J9 MIPI D-PHY -> MIPI CSI-2 RX Subsystem v6.0 (2-lane RAW10) -> v_demosaic (Bayer->RGB)
#   -> Frame Buffer Write (RGB888) -> PS DDR (HP1)
# axi_iic -> J9 I2C (G11/F10) ;  xlconstant 1 -> raspi_enable (F11, "HDA09" camera enable)
# Run:  vivado -mode batch -source tcl/build_bd.tcl     (cwd = vivado/)

set PROJ    kv260_imx477
set PART    xck26-sfvc784-2LV-c
set ORIGIN  [file normalize [file dirname [info script]]/..]
set BD      camctl

create_project $PROJ $ORIGIN/build/$PROJ -part $PART -force
set_property target_language Verilog [current_project]
create_bd_design $BD

proc cn {a b} {
  set pa [get_bd_pins -quiet $a] ; set pb [get_bd_pins -quiet $b]
  if {$pa eq "" || $pb eq ""} { error "cn: missing pin  a='$a'($pa)  b='$b'($pb)" }
  connect_bd_net $pa $pb
}
proc ci {a b} { connect_bd_intf_net [get_bd_intf_pins $a] [get_bd_intf_pins $b] }

# ---------------------------------------------------------------- PS (exact KV260 config from PYNQ base)
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps]
source "$ORIGIN/tcl/ps_config.tcl"
set_property -dict [list \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__FPGA_PL1_ENABLE {1} \
  CONFIG.PSU__FPGA_PL2_ENABLE {1} \
  CONFIG.PSU__USE__M_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP3 {1} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
  CONFIG.PSU__NUM_FABRIC_RESETS {4} \
] $ps

# ---------------------------------------------------------------- clocking : exact 200 MHz for the D-PHY core_clk,
# plus a SECOND, independent 200 MHz clock output for the CSI2RXSS video-domain group
# (2026-09-14: was ps/pl_clk2 at 300.030 MHz -- 20% over PG232's documented "Maximum
# video clock is 250MHz for UltraScale+ devices" limit for this exact IP, with only
# 0.089ns of static timing margin across 31828 endpoints in that domain. PG232 also
# says the fix for needing more than the max clock's throughput is Dual/Quad pixels
# per clock, not raising the clock past the max -- we don't need more throughput at
# all (our functional minimum is 56.25MHz per PG232's own formula), so just bringing
# the clock back under the documented cap on its own dedicated output, not sharing
# dphy_clk_200M's, to avoid adding fanout/jitter risk to that IP's own reference
# clock. See EXPERIMENT_LOG.md 2026-09-14 13:34 UTC entry for the 160-sample-
# periodic corruption finding that led here.
# The apparent row-655 truncation was limited to the sensor's synthetic test
# pattern; real captures were complete on the validated 200 MHz build.
set clkw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clkw]
set_property -dict [list \
  CONFIG.PRIM_IN_FREQ {99.999001} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.CLKOUT2_USED {true} \
  CONFIG.NUM_OUT_CLKS {2} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.USE_RESET {true} \
  CONFIG.RESET_TYPE {ACTIVE_LOW} \
  CONFIG.RESET_PORT {resetn} \
] $clkw
cn ps/pl_clk0    clkw/clk_in1
cn ps/pl_resetn0 clkw/resetn

# ---------------------------------------------------------------- resets
set rst100 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst100]
set rst300 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst300]
cn ps/pl_clk0 rst100/slowest_sync_clk
cn clkw/clk_out2 rst300/slowest_sync_clk
cn ps/pl_resetn0 rst100/ext_reset_in
cn ps/pl_resetn0 rst300/ext_reset_in
cn ps/pl_clk0 ps/maxihpm0_lpd_aclk
cn clkw/clk_out2 ps/saxihp1_fpd_aclk
cn ps/pl_clk0 ps/saxi_lpd_aclk

# ---------------------------------------------------------------- MIPI CSI-2 RX Subsystem v6.0
# C_HS_LINE_RATE=900 (Mbps/lane) -- was 1500 originally, which never matched the
# IMX477's actual link (link-frequencies=<450000000> in the driver/overlay, i.e.
# 450 MHz DDR = 900 Mbps/lane; this 900 number was even flagged as the correct one
# in this project's very first notes, back before Route A started, but Route A's own
# BD never used it). A wrong line rate misconfigures the D-PHY's CDR/PLL sampling and
# produces exactly the symptom seen live on hardware once real CSI-2 traffic finally
# flowed: incrementing CRC Error / Word Count Errors / Lane Stop State counts in
# xilinx-csi2rxss's IRQ handler (EXPERIMENT_LOG.md 2026-09-11 ~14:27), i.e. garbled
# receive, not a downstream consumer/drain problem as first suspected.
#
# DPY_LINE_RATE=900 too -- this is a SEPARATE property on the embedded D-PHY IP
# itself (not auto-synced with C_HS_LINE_RATE, the subsystem-wrapper property).
# Confirmed by probing the actual IP after only setting C_HS_LINE_RATE=900: this
# stayed at its default of 800, meaning the real D-PHY receiver hardware was
# calibrated for 800 Mbps this whole time regardless of C_HS_LINE_RATE -- almost
# certainly the ACTUAL cause of the CRC/lane-stop-state errors (the 900-only
# rebuild did not fix them; PYNQ's own working base.tcl sets both properties to the
# same value, which is what caught this).
set csi [create_bd_cell -type ip -vlnv xilinx.com:ip:mipi_csi2_rx_subsystem:6.0 csi]
set_property -dict [list \
  CONFIG.CMN_NUM_LANES {2} \
  CONFIG.C_DPHY_LANES {2} \
  CONFIG.CMN_NUM_PIXELS {1} \
  CONFIG.CMN_PXL_FORMAT {RAW10} \
  CONFIG.CMN_VC {All} \
  CONFIG.CSI_BUF_DEPTH {4096} \
  CONFIG.CSI_EMB_NON_IMG {false} \
  CONFIG.CSI_CONTROLLER_REG_IF {true} \
  CONFIG.C_CSI_FILTER_USERDATATYPE {true} \
  CONFIG.C_EN_CSI_V2_0 {false} \
  CONFIG.DPY_EN_REG_IF {true} \
  CONFIG.SupportLevel {1} \
  CONFIG.HP_IO_BANK_SELECTION {66} \
  CONFIG.C_HS_LINE_RATE {900} \
  CONFIG.DPY_LINE_RATE {900} \
  CONFIG.CLK_LANE_IO_LOC {D7} \
  CONFIG.DATA_LANE0_IO_LOC {E5} \
  CONFIG.DATA_LANE1_IO_LOC {G6} \
  CONFIG.C_CLK_LANE_IO_POSITION {26} \
  CONFIG.C_DATA_LANE0_IO_POSITION {28} \
  CONFIG.C_DATA_LANE1_IO_POSITION {30} \
] $csi

# ---------------------------------------------------------------- Frame Buffer Write v2.5
# Feeds from v_demosaic's RGB output now (was raw Bayer "y10"/"y8" directly from the
# CSI subset converter) -- xilinx-csi2rxss only ever reports Bayer-tagged mbus codes
# for RAW10 (xilinx-csi2rxss.c's per-datatype mbus table has no plain-mono entry), and
# xilinx_frmbuf's format table has no Bayer entry at all -- confirmed on hardware
# (EXPERIMENT_LOG.md 2026-09-11 14:43): dmaengine_prep_interleaved_dma always failed
# ("Invalid dma template or missing dma video fmt config") for any Bayer fourcc, no
# matter what the CSI ports' DT properties said. v_demosaic converts Bayer->RGB in
# hardware first, matching every proven AMD reference design (PYNQ's own `base`
# includes v_demosaic ahead of its VDMA for exactly this reason).
set fb [create_bd_cell -type ip -vlnv xilinx.com:ip:v_frmbuf_wr:2.5 fb]
# Disable every format then enable the demosaic driver's 8-bit RGB output.
set fbcfg [list \
  CONFIG.SAMPLES_PER_CLOCK {1} \
  CONFIG.AXIMM_DATA_WIDTH {128} \
  CONFIG.AXIMM_ADDR_WIDTH {32} \
  CONFIG.MAX_COLS {4096} \
  CONFIG.MAX_ROWS {4096} \
  CONFIG.MAX_DATA_WIDTH {8} ]
foreach h {HAS_BGR8 HAS_BGRX8 HAS_INTERLACED HAS_RGB16 HAS_RGBX10 HAS_RGBX12 HAS_RGBX8 \
           HAS_UYVY8 HAS_Y8 HAS_Y10 HAS_Y12 HAS_Y16 HAS_YUV16 HAS_YUV8 HAS_YUVX10 HAS_YUVX12 \
           HAS_YUVX8 HAS_YUYV8 HAS_Y_UV10 HAS_Y_UV10_420 HAS_Y_UV12 HAS_Y_UV12_420 HAS_Y_UV16 \
           HAS_Y_UV16_420 HAS_Y_UV8 HAS_Y_UV8_420 HAS_Y_U_V10 HAS_Y_U_V8 HAS_Y_U_V8_420} {
  lappend fbcfg CONFIG.$h {0}
}
lappend fbcfg CONFIG.HAS_RGB8 {1}
set_property -dict $fbcfg $fb

# v_demosaic 1.1: Bayer (10-bit, matches CSI RAW10) -> RGB. Confirmed on hardware
# (EXPERIMENT_LOG.md 2026-09-11 ~13:34): this IP/driver combo only ever enumerates
# ONE source-pad format, MEDIA_BUS_FMT_RBG888_1X24 (8-bit/channel, 24-bit, no
# padding) -- MAX_DATA_WIDTH=10 only affects the Bayer *input* side; output is fixed
# 8-bit RGB regardless. frmbuf's format needs to match that (HAS_RGB8/"bgr888"), not
# the 10-bit-per-channel RGBX10 originally guessed.
set demosaic [create_bd_cell -type ip -vlnv xilinx.com:ip:v_demosaic:1.1 demosaic]
set_property -dict [list \
  CONFIG.MAX_DATA_WIDTH {10} \
  CONFIG.MAX_COLS {4096} \
  CONFIG.MAX_ROWS {4096} \
  CONFIG.SAMPLES_PER_CLOCK {1} \
] $demosaic

# CSI RAW10 video_out (2-byte TDATA, native packing for a single 10-bit sample) ->
# demosaic s_axis_video directly -- Vivado's own bd validation (CRITICAL WARNING:
# TDATA_NUM_BYTES does not match between demosaic/s_axis_video(2) and a 4-byte
# subset-converter output) caught that demosaic's Bayer *input* wants CSI's native
# 2-byte width, not the wider 4-byte convention v_frmbuf_wr's own (mono Y10) input
# needed in the pre-demosaic design -- so no subset converter is needed on this leg
# at all.
ci csi/video_out demosaic/s_axis_video

# ---------------------------------------------------------------- debug: System ILA
# tapping csi/video_out (the very first AXI4-Stream point after D-PHY+CSI-2 packet
# processing, before demosaic ever sees it). If corruption is already visible here,
# the fault is inside CSI2RXSS/D-PHY itself; if this looks clean, corruption is
# happening downstream. JTAG confirmed reachable over the same USB cable as the
# serial console (2026-09-14) -- Xilinx X-MLCC-01 cable, xck26 fpga tap detected.
set ila [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 ila]
set_property -dict [list \
  CONFIG.C_MON_TYPE {INTERFACE} \
  CONFIG.C_NUM_MONITOR_SLOTS {1} \
  CONFIG.C_SLOT_0_INTF_TYPE {xilinx.com:interface:axis_rtl:1.0} \
  CONFIG.C_DATA_DEPTH {1024} \
] $ila
# Shrunk from 4096 -> 1024 samples (2026-09-14): the 4096-depth build had WNS=-0.012 ns,
# failing *inside* the D-PHY's own clock-lane init logic (dphy_rx_clk_lane) -- exactly
# the circuit under study, so BER measurements from that build could be self-tainted.
# Smaller ILA BRAM footprint to get comfortably positive timing back before trusting
# quantitative bit-error-rate numbers.
# Live JTAG connect (2026-09-14) rejected the first ILA build's probes file:
# "This port location for the ILA core ... does not support a data probe" on the
# TDATA probe -- ALL_PROBE_SAME_MU_CNT defaults to 1 (trigger-only-capable match
# units), which apparently isn't enough for a wide auto-generated interface data
# probe to be captured. Bumping to 2 (trigger+capture) fixed TDATA specifically,
# but the SAME error then reappeared on TDEST (port index 1) -- TDEST/TID default
# to AUTO-detected width and get auto-included even though our video_out doesn't
# use them meaningfully. Excluding both entirely rather than chasing this per-port.
set_property CONFIG.ALL_PROBE_SAME_MU_CNT {2} $ila
set_property CONFIG.C_SLOT_0_AXIS_TDEST_WIDTH {0} $ila
set_property CONFIG.C_SLOT_0_AXIS_TID_WIDTH {0} $ila
ci csi/video_out ila/SLOT_0_AXIS

# demosaic's RGB output (m_axis_video) is 4 bytes/pixel (RBG888 padded to the
# generic video-IP word convention -- confirmed by ANOTHER Vivado critical warning:
# TDATA_NUM_BYTES mismatch, fb/s_axis_video(3) vs demosaic/m_axis_video(4), since
# frmbuf's "bgr888"/HAS_RGB8 format is tightly packed at 3 bytes/pixel with no
# padding). Subset converter strips the padding byte (bits[31:24]).
set ssc2 [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 ssc2]
set_property -dict [list \
  CONFIG.S_TDATA_NUM_BYTES {4} \
  CONFIG.M_TDATA_NUM_BYTES {3} \
  CONFIG.S_HAS_TLAST {1} \
  CONFIG.M_HAS_TLAST {1} \
  CONFIG.S_TUSER_WIDTH {1} \
  CONFIG.M_TUSER_WIDTH {1} \
  CONFIG.TDATA_REMAP {tdata[23:0]} \
  CONFIG.TUSER_REMAP {tuser[0:0]} \
] $ssc2
ci demosaic/m_axis_video ssc2/S_AXIS
ci ssc2/M_AXIS            fb/s_axis_video

# ---------------------------------------------------------------- axi_iic -> J9 I2C
set iic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 iic]
set_property -dict [list CONFIG.IIC_FREQ_KHZ {100} CONFIG.C_GPO_WIDTH {1}] $iic
make_bd_intf_pins_external [get_bd_intf_pins iic/IIC]
set_property name iic [get_bd_intf_ports IIC_0]

# ---------------------------------------------------------------- raspi_enable const 1 -> F11
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one
create_bd_port -dir O raspi_enable
connect_bd_net [get_bd_pins one/dout] [get_bd_ports raspi_enable]

# ---------------------------------------------------------------- frmbuf soft-reset GPIO (the xilinx-frmbuf driver requires reset-gpios)
set rstgpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 rstgpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_IS_DUAL {0} CONFIG.C_DOUT_DEFAULT {0x00000000}] $rstgpio
cn rstgpio/gpio_io_o fb/ap_rst_n

# xilinx-demosaic.c also requires an explicit reset-gpios (devm_gpiod_get(dev, "reset")) --
# its own GPIO, mirroring rstgpio above exactly.
set rstgpio2 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 rstgpio2]
set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_IS_DUAL {0} CONFIG.C_DOUT_DEFAULT {0x00000000}] $rstgpio2
cn rstgpio2/gpio_io_o demosaic/ap_rst_n

# ---------------------------------------------------------------- MIPI phy external
make_bd_intf_pins_external [get_bd_intf_pins csi/mipi_phy_if]
set_property name mipi_phy_if [get_bd_intf_ports mipi_phy_if_0]

# ---------------------------------------------------------------- AXI-Lite control (HPM0_LPD -> iic, csi, fb, rstgpio)
# Using the classic axi_interconnect (not smartconnect) -- this is the exact IP class
# PYNQ's base design uses for its own working axi_iic control path on this same board;
# a live-hardware test earlier this session proved MMIO through it (PYNQ base) does NOT
# hang. A smartconnect-based control path here reproducibly hung on the first real
# register access (see STATUS.md); switching topology to remove that as a variable.
set aic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 aic]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] $aic
ci ps/M_AXI_HPM0_LPD aic/S00_AXI
ci aic/M00_AXI iic/S_AXI
ci aic/M01_AXI csi/csirxss_s_axi
ci aic/M02_AXI fb/s_axi_CTRL
ci aic/M03_AXI rstgpio/S_AXI
ci aic/M04_AXI demosaic/s_axi_CTRL
ci aic/M05_AXI rstgpio2/S_AXI

# ---------------------------------------------------------------- data path frmbuf -> HP1
set smcd [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smcd]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $smcd
ci fb/m_axi_mm_video smcd/S00_AXI
ci smcd/M00_AXI ps/S_AXI_HP1_FPD

# ---------------------------------------------------------------- clocks
# axi_interconnect: global ACLK/ARESETN + per-port ACLK/ARESETN (native async clock
# conversion on M02, which faces v_frmbuf_wr's 300 MHz-only s_axi_CTRL).
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins aic/ACLK] [get_bd_pins aic/S00_ACLK] \
  [get_bd_pins aic/M00_ACLK] [get_bd_pins aic/M01_ACLK] [get_bd_pins aic/M03_ACLK] [get_bd_pins aic/M05_ACLK] \
  [get_bd_pins iic/s_axi_aclk] [get_bd_pins csi/lite_aclk] [get_bd_pins rstgpio/s_axi_aclk] \
  [get_bd_pins rstgpio2/s_axi_aclk]
connect_bd_net [get_bd_pins clkw/clk_out2] [get_bd_pins aic/M02_ACLK] [get_bd_pins aic/M04_ACLK] \
  [get_bd_pins smcd/aclk] [get_bd_pins csi/video_aclk] [get_bd_pins fb/ap_clk] \
  [get_bd_pins demosaic/ap_clk] [get_bd_pins ssc2/aclk] [get_bd_pins ila/clk]
cn clkw/clk_out1 csi/dphy_clk_200M

# ---------------------------------------------------------------- resets
connect_bd_net [get_bd_pins rst100/peripheral_aresetn] [get_bd_pins aic/ARESETN] [get_bd_pins aic/S00_ARESETN] \
  [get_bd_pins aic/M00_ARESETN] [get_bd_pins aic/M01_ARESETN] [get_bd_pins aic/M03_ARESETN] \
  [get_bd_pins aic/M05_ARESETN] [get_bd_pins iic/s_axi_aresetn] [get_bd_pins csi/lite_aresetn] \
  [get_bd_pins rstgpio/s_axi_aresetn] [get_bd_pins rstgpio2/s_axi_aresetn]
connect_bd_net [get_bd_pins rst300/peripheral_aresetn] [get_bd_pins aic/M02_ARESETN] \
  [get_bd_pins aic/M04_ARESETN] [get_bd_pins smcd/aresetn] [get_bd_pins csi/video_aresetn] \
  [get_bd_pins ssc2/aresetn] [get_bd_pins ila/resetn]

# ---------------------------------------------------------------- interrupts
# pl_ps_irq0[3:0]  ->  GIC SPI  <0 89 4> (csi)  <0 90 4> (frmbuf)  <0 91 4> (iic)  <0 92 4> (demosaic)
set irqcat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irqcat]
set_property CONFIG.NUM_PORTS {4} $irqcat
cn csi/csirxss_csi_irq  irqcat/In0
cn fb/interrupt         irqcat/In1
cn iic/iic2intc_irpt    irqcat/In2
cn demosaic/interrupt   irqcat/In3
cn irqcat/dout          ps/pl_ps_irq0

# ---------------------------------------------------------------- address map
assign_bd_address -offset 0x80000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs csi/csirxss_s_axi/Reg] -force
assign_bd_address -offset 0x80010000 -range 0x00010000 -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs fb/s_axi_CTRL/Reg] -force
assign_bd_address -offset 0x80030000 -range 0x00010000 -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs iic/S_AXI/Reg] -force
assign_bd_address -offset 0x80020000 -range 0x00010000 -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs rstgpio/S_AXI/Reg] -force
assign_bd_address -offset 0x80040000 -range 0x00010000 -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs demosaic/s_axi_CTRL/Reg] -force
assign_bd_address -offset 0x80050000 -range 0x00010000 -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs rstgpio2/S_AXI/Reg] -force
assign_bd_address -offset 0x00000000 -range 0x80000000 -target_address_space [get_bd_addr_spaces fb/Data_m_axi_mm_video] [get_bd_addr_segs ps/SAXIGP3/HP1_DDR_LOW] -force

regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files $ORIGIN/build/$PROJ/$PROJ.srcs/sources_1/bd/$BD/$BD.bd] -top
add_files -norecurse $ORIGIN/build/$PROJ/$PROJ.gen/sources_1/bd/$BD/hdl/${BD}_wrapper.v
set_property top ${BD}_wrapper [current_fileset]
add_files -fileset constrs_1 -norecurse $ORIGIN/xdc/kv260_imx477.xdc
update_compile_order -fileset sources_1
puts "=== build_bd.tcl complete ==="
