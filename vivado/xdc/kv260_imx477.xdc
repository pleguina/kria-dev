# KV260 IMX477 raw-CSI design constraints
# MIPI D-PHY pin placement is done inside the CSI-2 RX Subsystem IP (C_*_IO_LOC),
# so only the differential terminations are needed on the top-level ports.
# Pins mirror the PYNQ KV260 'base' design (J9 Raspberry Pi camera connector).

# ---- MIPI D-PHY (J9), MPSoC HPA bank 66 ----
set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_clk_p}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_clk_n}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_data_p[*]}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_data_n[*]}]

# ---- I2C to J9 camera (through the carrier pca9546, mux ch2) ----
set_property PACKAGE_PIN G11 [get_ports iic_scl_io]
set_property PACKAGE_PIN F10 [get_ports iic_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports {iic_scl_io iic_sda_io}]

# ---- Raspberry Pi camera enable (HDA09) : must be driven HIGH ----
set_property PACKAGE_PIN F11 [get_ports raspi_enable]
set_property IOSTANDARD LVCMOS33 [get_ports raspi_enable]

set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN ENABLE [current_design]
