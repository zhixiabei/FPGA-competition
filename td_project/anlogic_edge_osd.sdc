create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
# Both recognition modes use this asynchronous UART input. Only its first
# synchronizer stage is excluded; the following stages remain normally timed.
set_false_path -from [get_ports {I_resnet_uart_rx}] -to [get_regs {*u_resnet18/uart/rx_meta *u_handcnn/uart/rx_meta}]
# Display controls and SW1 are asynchronous; only synchronizers sample them.
# The following synchronizer stage and debounce logic remain normally timed.
set_false_path -from [get_ports {I_mode_key_n}]
set_false_path -from [get_ports {I_effect_key_n}]
set_false_path -from [get_ports {I_latency_switch}]
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
# Optional camera payloads share the live class-mailbox collection below;
# disabling the four camera indicators must not leave an empty constraint.
set_max_delay -datapath_only -from [get_regs -nowarn {u_ae_stats_cdc/payload_hold[*]}] -to [get_regs -nowarn {u_ae_stats_cdc/O_dst_data[*]}] 20.000

# Latency mailboxes cross CSI/DDR/HDMI; their payload bounds must remain
# active. TD's broad asynchronous groups would override those bounds.
# Use relaxed datapath limits for those pairs, then constrain the specific
# held payloads and single-step Gray source below.
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]
set_clock_groups -asynchronous \
    -group [get_clocks {pll_clk_24m}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# HDMI pixel and camera clocks must not be grouped away: the raw-statistics
# mailbox payload is bounded to 13 ns, below two HDMI request stages.
# Display settings cross CSI -> DDR -> HDMI in held payload mailboxes.
set_max_delay -datapath_only -from [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] -to [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] -to [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] -to [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] 100.000
set_max_delay -datapath_only -from [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] -to [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {HDMI_PIXEL_CLK}] -to [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] 100.000
set_max_delay -datapath_only -from [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] -to [get_clocks {HDMI_PIXEL_CLK}] 100.000

# Keep this bound after the broad limits: TD gives later max-delay rules priority.
# Display mode crosses sys_clk_50m -> CSI in one held-payload mailbox.
# The CSI frame commits that snapshot; its DDR-slot record then crosses to
# HDMI through the 12-bit u_effect_frame_bridge mailbox.
# A union keeps these selectors nonempty in both prototype and legacy builds.
# Paths only exist within each mailbox; this excludes first synchronizers only.
set_false_path -from [get_regs {u_display_effect_cdc/req_toggle *u_status_cdc/req_toggle *u_hand_box_cdc/req_toggle *u_cnn_result_cdc/request}] -to [get_regs {u_display_effect_cdc/req_meta *u_status_cdc/req_meta *u_hand_box_cdc/req_meta *u_cnn_result_cdc/req_meta}]
set_false_path -from [get_regs {u_display_effect_cdc/ack_toggle *u_status_cdc/ack_toggle *u_hand_box_cdc/ack_toggle}] -to [get_regs {u_display_effect_cdc/ack_meta *u_status_cdc/ack_meta *u_hand_box_cdc/ack_meta}]
set_max_delay -datapath_only -from [get_regs {u_display_effect_cdc/payload_hold[*]}] -to [get_regs {u_display_effect_cdc/O_dst_data[*]}] 13.000

set_false_path -from [get_regs {u_video_latency/S_isp_request}] -to [get_regs {u_video_latency/S_isp_req_meta}]
set_false_path -from [get_regs {u_video_latency/S_isp_ack}] -to [get_regs {u_video_latency/S_isp_ack_meta}]
set_false_path -from [get_regs {u_video_latency/S_read_request}] -to [get_regs {u_video_latency/S_read_req_meta}]
set_false_path -from [get_regs {u_video_latency/S_read_ack}] -to [get_regs {u_video_latency/S_read_ack_meta}]
# A registered Gray value changes one bit per microsecond. 20 ns is much
# shorter than that update interval; the second synchronizer is timed normally.
set_max_delay -datapath_only -from [get_regs {u_video_latency/u_timebase/O_time_gray[*]}] -to [get_regs {u_video_latency/S_csi_gray_meta[*] u_video_latency/S_hdmi_gray_meta[*]}] 20.000
# ISP SOF and its held tag share the existing two-stage video_in SOF crossing.
set_max_delay -datapath_only -from [get_regs {u_video_latency/S_start_id[*] u_video_latency/S_start_raw_us[*] u_video_latency/S_start_valid}] -to [get_regs {u_video_latency/S_slot*}] 20.000
set_max_delay -datapath_only -from [get_regs {u_video_latency/S_isp_payload[*]}] -to [get_regs {u_video_latency/S_slot* u_video_latency/S_last_isp_payload[*]}] 20.000
set_max_delay -datapath_only -from [get_regs {u_video_latency/S_read_payload[*]}] -to [get_regs {u_video_latency/S_pending_payload[*] u_video_latency/S_pending_valid}] 13.000

set_false_path -from [get_regs {u_effect_frame_bridge/S_read_request}] -to [get_regs {u_effect_frame_bridge/S_read_req_meta}]
set_false_path -from [get_regs {u_effect_frame_bridge/S_read_ack}] -to [get_regs {u_effect_frame_bridge/S_read_ack_meta}]

# CNN result mailbox: the held payload and request toggle cross from the
# MIPI byte-clock domain to HDMI. Only the first destination synchronizer is
# asynchronous; the payload remains stable until the toggle is observed.
# The held payload is bounded in either mode. The legacy class payload is now
# timed rather than false-pathed; the probe uses a full acknowledgement mailbox.
set_max_delay -datapath_only -from [get_regs -nowarn {u_camera_diag_cdc/payload_hold[*] raw_diagnostics$u_cdc/payload_hold[*] raw_diagnostics$u_ae_readout_cdc/payload_hold[*] *u_status_cdc/payload_hold[*] *u_hand_box_cdc/payload_hold[*] *u_cnn_result_cdc/payload[*]}] -to [get_regs -nowarn {u_camera_diag_cdc/O_dst_data[*] raw_diagnostics$u_cdc/O_dst_data[*] raw_diagnostics$u_ae_readout_cdc/O_dst_data[*] *u_status_cdc/O_dst_data[*] *u_hand_box_cdc/O_dst_data[*] *u_cnn_result_cdc/class_meta[*]}] 13.000

# CSI settings are stable until the next SOF, and sampled after video_in synchronizes SOF.
set_max_delay -datapath_only -from [get_regs {u_effect_frame_bridge/S_start_effect_config[*]}] -to [get_regs {u_effect_frame_bridge/S_slot_effect_config*}] 20.000
set_max_delay -datapath_only -from [get_regs {u_effect_frame_bridge/S_read_payload[*]}] -to [get_regs {u_effect_frame_bridge/O_effect_config[*]}] 13.000

# SW1 is sampled by the first HDMI synchronizer; the second stage remains timed.
set_false_path -from [get_ports {I_latency_switch}] -to [get_regs {u_hdmi_mixer/latency_switch$show_meta}]

# KEY4: exclude only the first asynchronous synchronizer input.
set_false_path -from [get_ports {I_param_key_n}] -to [get_regs {*u_handcnn/key_control/key_meta}]
