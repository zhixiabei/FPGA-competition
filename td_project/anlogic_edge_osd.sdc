create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
# K1/K2 are asynchronous; only the button synchronizers sample these ports.
# The following synchronizer stage and debounce logic remain normally timed.
set_false_path -from [get_ports {I_mode_key_n}]
set_false_path -from [get_ports {I_detect_key_n}]
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]

# Only the first request/ACK synchronizers are asynchronous. Include optional
# statistics mailboxes with the always-present camera diagnostic mailbox so
# the collections remain valid when diagnostics are disabled/optimized away.
# Mailboxes have no combinational paths to each other's destination registers.
# TD does not reliably apply constraints inside SDC conditionals.
set_false_path -from [get_regs -nowarn {u_camera_diag_cdc/req_toggle u_ae_stats_cdc/req_toggle raw_diagnostics$u_cdc/req_toggle raw_diagnostics$u_ae_readout_cdc/req_toggle}] -to [get_regs -nowarn {u_camera_diag_cdc/req_meta u_ae_stats_cdc/req_meta raw_diagnostics$u_cdc/req_meta raw_diagnostics$u_ae_readout_cdc/req_meta}]
set_false_path -from [get_regs -nowarn {u_camera_diag_cdc/ack_toggle u_ae_stats_cdc/ack_toggle raw_diagnostics$u_cdc/ack_toggle raw_diagnostics$u_ae_readout_cdc/ack_toggle}] -to [get_regs -nowarn {u_camera_diag_cdc/ack_meta u_ae_stats_cdc/ack_meta raw_diagnostics$u_cdc/ack_meta raw_diagnostics$u_ae_readout_cdc/ack_meta}]
# Stable diagnostic payloads are held until ACK; 13 ns is below two request
# stages. AE statistics cross to 24 MHz and retain their separate 20 ns bound.
set_max_delay -datapath_only -from [get_regs -nowarn {u_camera_diag_cdc/payload_hold[*] raw_diagnostics$u_cdc/payload_hold[*] raw_diagnostics$u_ae_readout_cdc/payload_hold[*]}] -to [get_regs -nowarn {u_camera_diag_cdc/O_dst_data[*] raw_diagnostics$u_cdc/O_dst_data[*] raw_diagnostics$u_ae_readout_cdc/O_dst_data[*]}] 13.000
set_max_delay -datapath_only -from [get_regs -nowarn {u_ae_stats_cdc/payload_hold[*]}] -to [get_regs -nowarn {u_ae_stats_cdc/O_dst_data[*]}] 20.000

# Leave pll_clk_24m out of the MIPI group exception so it cannot override
# the mailbox payload bounds. DDR crossings retain their original exception.
set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]
set_clock_groups -asynchronous \
    -group [get_clocks {pll_clk_24m}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# HDMI pixel and camera clocks must not be grouped away: the raw-statistics
# mailbox payload is bounded to 13 ns, below two HDMI request stages.
# The existing target mailbox shares these clocks; bound it too.
set_false_path -from [get_regs {S_target_request}] -to [get_regs {S_target_toggle_meta}]
set_false_path -from [get_regs {S_target_ack}] -to [get_regs {S_target_ack_meta}]
set_max_delay -datapath_only -from [get_regs {S_target_mailbox[*]}] 20.000
set_clock_groups -asynchronous \
    -group [get_clocks {HDMI_PIXEL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# The mode key crosses into the camera clock domain through the mode synchronizer.
set_false_path -from [get_regs {u_video_mode_control/O_edge_mode}] -to [get_regs {u_isp_top/u_rgb_edge_switch/mode_meta}]
# K2 selects detection only at a camera frame boundary.
set_false_path -from [get_regs {u_detection_mode_control/O_edge_mode}] -to [get_regs {u_isp_top/u_target_detect_switch/mode_meta}]
