create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
# K1 is asynchronous; only the first input synchronizer samples the raw port.
set_false_path -from [get_ports {I_mode_key_n}]
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_video/u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]

# Keep diagnostic toggle exceptions limited to the first synchronizer.
set_false_path -from [get_regs {u_video/u_camera_diag_cdc/req_toggle}] -to [get_regs {u_video/u_camera_diag_cdc/req_meta}]
set_false_path -from [get_regs {u_video/u_camera_diag_cdc/ack_toggle}] -to [get_regs {u_video/u_camera_diag_cdc/ack_meta}]
# The stable snapshot is still constrained, independently of clock phase.
set_max_delay -datapath_only -from [get_regs {u_video/u_camera_diag_cdc/payload_hold[*]}] -to [get_regs {u_video/u_camera_diag_cdc/O_dst_data[*]}] 13.000

# AE statistics remain stable until ACK; the two destination request
# stages guarantee at least 84 ns before capture. Do not group away the
# 20 ns payload constraint.
set_false_path -from [get_regs {u_video/u_ae_stats_cdc/req_toggle}] -to [get_regs {u_video/u_ae_stats_cdc/req_meta}]
set_false_path -from [get_regs {u_video/u_ae_stats_cdc/ack_toggle}] -to [get_regs {u_video/u_ae_stats_cdc/ack_meta}]
set_max_delay -datapath_only -from [get_regs {u_video/u_ae_stats_cdc/payload_hold[*]}] -to [get_regs {u_video/u_ae_stats_cdc/O_dst_data[*]}] 20.000

set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]
set_clock_groups -asynchronous \
    -group [get_clocks {pll_clk_24m}] \
    -group [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]
