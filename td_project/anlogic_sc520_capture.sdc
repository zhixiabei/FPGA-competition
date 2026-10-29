create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
# K1-K3 and SW1 are asynchronous; only their synchronizers sample these ports.
set_false_path -from [get_ports {I_mode_key_n}]
set_false_path -from [get_ports {I_detect_key_n}]
set_false_path -from [get_ports {I_effect_key_n}]
set_false_path -from [get_ports {I_latency_switch}]
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_video/u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_video/u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]

# First-stage request/ACK exceptions for live and optional mailboxes.
# The always-present camera mailbox keeps each collection nonempty when
# diagnostics are removed. No combinational paths connect different mailboxes.
# Use direct SDC commands: conditional SDC bodies are unreliable in TD.
set_false_path -from [get_regs -nowarn {u_video/u_camera_diag_cdc/req_toggle u_video/u_ae_stats_cdc/req_toggle u_video/raw_diagnostics$u_cdc/req_toggle u_video/raw_diagnostics$u_ae_readout_cdc/req_toggle}] -to [get_regs -nowarn {u_video/u_camera_diag_cdc/req_meta u_video/u_ae_stats_cdc/req_meta u_video/raw_diagnostics$u_cdc/req_meta u_video/raw_diagnostics$u_ae_readout_cdc/req_meta}]
set_false_path -from [get_regs -nowarn {u_video/u_camera_diag_cdc/ack_toggle u_video/u_ae_stats_cdc/ack_toggle u_video/raw_diagnostics$u_cdc/ack_toggle u_video/raw_diagnostics$u_ae_readout_cdc/ack_toggle}] -to [get_regs -nowarn {u_video/u_camera_diag_cdc/ack_meta u_video/u_ae_stats_cdc/ack_meta u_video/raw_diagnostics$u_cdc/ack_meta u_video/raw_diagnostics$u_ae_readout_cdc/ack_meta}]
# Camera/RAW display diagnostics are disabled in the production top and their
# destination registers are optimized away. AE statistics remain active and
# retain their separate 20 ns bundled-data bound.
set_max_delay -datapath_only -from [get_regs -nowarn {u_video/u_ae_stats_cdc/payload_hold[*]}] -to [get_regs -nowarn {u_video/u_ae_stats_cdc/O_dst_data[*]}] 20.000
# Original-compatible AWB ignores the AE hold input in the production build.

# Keep timestamp and held-payload crossings bounded instead of grouping
# their clocks away. These exceptions match the main project with u_video.
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]
set_clock_groups -asynchronous \
    -group [get_clocks {pll_clk_24m}] \
    -group [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# HDMI pixel and camera clocks must not be grouped away: the raw-statistics
# mailbox payload is bounded to 13 ns, below two HDMI request stages.
# The existing target mailbox shares these clocks; bound it too.
# Target metadata crosses CSI -> DDR -> HDMI in held payload mailboxes.
set_max_delay -datapath_only -from [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] -to [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] -to [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] -to [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] 100.000
set_max_delay -datapath_only -from [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] -to [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {HDMI_PIXEL_CLK}] -to [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] 100.000
set_max_delay -datapath_only -from [get_clocks {u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_video/u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] -to [get_clocks {HDMI_PIXEL_CLK}] 100.000

# Keep this bound after the broad limits: TD gives later max-delay rules priority.
# Display mode crosses sys_clk_50m -> CSI in one held-payload mailbox.
# The CSI frame commits that snapshot; its DDR-slot record then crosses to
# HDMI through u_target_frame_bridge, including the configuration bits.
set_false_path -from [get_regs {u_video/u_display_effect_cdc/req_toggle}] -to [get_regs {u_video/u_display_effect_cdc/req_meta}]
set_false_path -from [get_regs {u_video/u_display_effect_cdc/ack_toggle}] -to [get_regs {u_video/u_display_effect_cdc/ack_meta}]
set_max_delay -datapath_only -from [get_regs {u_video/u_display_effect_cdc/payload_hold[*]}] -to [get_regs {u_video/u_display_effect_cdc/O_dst_data[*]}] 13.000

set_false_path -from [get_regs {u_video/latency_diagnostics$u_video_latency/S_isp_request}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_isp_req_meta}]
set_false_path -from [get_regs {u_video/latency_diagnostics$u_video_latency/S_isp_ack}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_isp_ack_meta}]
set_false_path -from [get_regs {u_video/latency_diagnostics$u_video_latency/S_read_request}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_read_req_meta}]
set_false_path -from [get_regs {u_video/latency_diagnostics$u_video_latency/S_read_ack}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_read_ack_meta}]
set_max_delay -datapath_only -from [get_regs {u_video/latency_diagnostics$u_video_latency/u_timebase/O_time_gray[*]}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_csi_gray_meta[*] u_video/latency_diagnostics$u_video_latency/S_hdmi_gray_meta[*]}] 20.000
set_max_delay -datapath_only -from [get_regs {u_video/latency_diagnostics$u_video_latency/S_start_id[*] u_video/latency_diagnostics$u_video_latency/S_start_raw_us[*] u_video/latency_diagnostics$u_video_latency/S_start_valid}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_slot*}] 20.000
set_max_delay -datapath_only -from [get_regs {u_video/latency_diagnostics$u_video_latency/S_isp_payload[*]}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_slot* u_video/latency_diagnostics$u_video_latency/S_last_isp_payload[*]}] 20.000
set_max_delay -datapath_only -from [get_regs {u_video/latency_diagnostics$u_video_latency/S_read_payload[*]}] -to [get_regs {u_video/latency_diagnostics$u_video_latency/S_pending_payload[*] u_video/latency_diagnostics$u_video_latency/S_pending_valid}] 13.000

set_false_path -from [get_regs {u_video/u_target_frame_bridge/S_result_request}] -to [get_regs {u_video/u_target_frame_bridge/S_result_req_meta}]
set_false_path -from [get_regs {u_video/u_target_frame_bridge/S_result_ack}] -to [get_regs {u_video/u_target_frame_bridge/S_result_ack_meta}]
set_false_path -from [get_regs {u_video/u_target_frame_bridge/S_read_request}] -to [get_regs {u_video/u_target_frame_bridge/S_read_req_meta}]
set_false_path -from [get_regs {u_video/u_target_frame_bridge/S_read_ack}] -to [get_regs {u_video/u_target_frame_bridge/S_read_ack_meta}]
set_max_delay -datapath_only -from [get_regs {u_video/u_target_frame_bridge/S_start_nonce[*] u_video/u_target_frame_bridge/S_start_frame_id[*] u_video/u_target_frame_bridge/S_start_effect_config[*] u_video/u_target_frame_bridge/S_start_motion_mode u_video/u_target_frame_bridge/S_start_color_mode[*] u_video/u_target_frame_bridge/S_start_valid}] -to [get_regs {u_video/u_target_frame_bridge/S_slot*}] 20.000
set_max_delay -datapath_only -from [get_regs {u_video/u_target_frame_bridge/S_result_payload[*]}] -to [get_regs {u_video/u_target_frame_bridge/S_slot* u_video/u_target_frame_bridge/S_last_result_payload[*]}] 20.000
set_max_delay -datapath_only -from [get_regs {u_video/u_target_frame_bridge/S_read_payload[*]}] -to [get_regs {u_video/u_target_frame_bridge/O_*}] 13.000

# K2 selects detection only at a camera frame boundary.
set_false_path -from [get_regs {u_video/u_detection_mode_control/O_detection_mode[*]}] -to [get_regs {u_video/u_isp_top/u_target_detect_switch/color_meta[*]}]
# SW1 is sampled by the first HDMI synchronizer; the second stage remains timed.
set_false_path -from [get_ports {I_latency_switch}] -to [get_regs {u_video/u_hdmi_mixer/latency_switch$show_meta}]

# The video-only wrapper keeps UART and SW2 ports but does not instantiate CNN.

# HX711 DOUT and SW2 are asynchronous to the DDR user clock.
set_false_path -from [get_ports {I_hx711_dout}] -to [get_regs -nowarn {*u_checkout/u_adc/dout_meta}]
set_false_path -from [get_ports {I_fruit_switch}] -to [get_regs -nowarn {*u_checkout/u_tare/key_meta *u_checkout/u_cal/key_meta *u_detection_mode_control/key_meta}]
