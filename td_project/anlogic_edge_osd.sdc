create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
# U30 return data is synchronized before sampling at SPI's divided clock.
# The second stage and SPI state machine retain normal timing checks.
set_false_path -from [get_ports I_model_flash_miso] -to [get_regs {handcnn_recognition$u_handcnn/flash_model$boot/reader/bus/miso_meta}]
# K1-K3 and SW1 are asynchronous; only their synchronizers sample these ports.
# The following synchronizer stage and debounce logic remain normally timed.
set_false_path -from [get_ports {I_mode_key_n}]
set_false_path -from [get_ports {I_detect_key_n}]
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
# IQ diagnostic payload destinations are optimized away in the production
# configuration. AE statistics remain active and keep their bundled-data bound.
set_max_delay -datapath_only -from [get_regs -nowarn {u_ae_stats_cdc/payload_hold[*]}] -to [get_regs -nowarn {u_ae_stats_cdc/O_dst_data[*]}] 20.000
# Original-compatible AWB ignores the AE hold input, so its destination is not
# a functional CDC endpoint in this build.

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
# Target metadata crosses CSI -> DDR -> HDMI in held payload mailboxes.
set_max_delay -datapath_only -from [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] -to [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {sys_clk_50m pll_clk_100m HDMI_SERIAL_CLK}] -to [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] -to [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] 100.000
set_max_delay -datapath_only -from [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] -to [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] 100.000
set_max_delay -datapath_only -from [get_clocks {HDMI_PIXEL_CLK}] -to [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] 100.000
set_max_delay -datapath_only -from [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] -to [get_clocks {HDMI_PIXEL_CLK}] 100.000

# Keep this bound after the broad limits: TD gives later max-delay rules priority.
# Display mode crosses sys_clk_50m -> CSI in one held-payload mailbox.
# The CSI frame commits that snapshot; its DDR-slot record then crosses to
# HDMI through u_target_frame_bridge, including the configuration bits.
set_false_path -from [get_regs {u_display_effect_cdc/req_toggle}] -to [get_regs {u_display_effect_cdc/req_meta}]
set_false_path -from [get_regs {u_display_effect_cdc/ack_toggle}] -to [get_regs {u_display_effect_cdc/ack_meta}]
set_max_delay -datapath_only -from [get_regs {u_display_effect_cdc/payload_hold[*]}] -to [get_regs {u_display_effect_cdc/O_dst_data[*]}] 13.000

set_false_path -from [get_regs {latency_diagnostics$u_video_latency/S_isp_request}] -to [get_regs {latency_diagnostics$u_video_latency/S_isp_req_meta}]
set_false_path -from [get_regs {latency_diagnostics$u_video_latency/S_isp_ack}] -to [get_regs {latency_diagnostics$u_video_latency/S_isp_ack_meta}]
set_false_path -from [get_regs {latency_diagnostics$u_video_latency/S_read_request}] -to [get_regs {latency_diagnostics$u_video_latency/S_read_req_meta}]
set_false_path -from [get_regs {latency_diagnostics$u_video_latency/S_read_ack}] -to [get_regs {latency_diagnostics$u_video_latency/S_read_ack_meta}]
# A registered Gray value changes one bit per microsecond. 20 ns is much
# shorter than that update interval; the second synchronizer is timed normally.
set_max_delay -datapath_only -from [get_regs {latency_diagnostics$u_video_latency/u_timebase/O_time_gray[*]}] -to [get_regs {latency_diagnostics$u_video_latency/S_csi_gray_meta[*] latency_diagnostics$u_video_latency/S_hdmi_gray_meta[*]}] 20.000
# ISP SOF and its held tag share the existing two-stage video_in SOF crossing.
set_max_delay -datapath_only -from [get_regs {latency_diagnostics$u_video_latency/S_start_id[*] latency_diagnostics$u_video_latency/S_start_raw_us[*] latency_diagnostics$u_video_latency/S_start_valid}] -to [get_regs {latency_diagnostics$u_video_latency/S_slot*}] 20.000
set_max_delay -datapath_only -from [get_regs {latency_diagnostics$u_video_latency/S_isp_payload[*]}] -to [get_regs {latency_diagnostics$u_video_latency/S_slot* latency_diagnostics$u_video_latency/S_last_isp_payload[*]}] 20.000
set_max_delay -datapath_only -from [get_regs {latency_diagnostics$u_video_latency/S_read_payload[*]}] -to [get_regs {latency_diagnostics$u_video_latency/S_pending_payload[*] latency_diagnostics$u_video_latency/S_pending_valid}] 13.000

set_false_path -from [get_regs {u_target_frame_bridge/S_result_request}] -to [get_regs {u_target_frame_bridge/S_result_req_meta}]
set_false_path -from [get_regs {u_target_frame_bridge/S_result_ack}] -to [get_regs {u_target_frame_bridge/S_result_ack_meta}]
set_false_path -from [get_regs {u_target_frame_bridge/S_read_request}] -to [get_regs {u_target_frame_bridge/S_read_req_meta}]
set_false_path -from [get_regs {u_target_frame_bridge/S_read_ack}] -to [get_regs {u_target_frame_bridge/S_read_ack_meta}]

set_max_delay -datapath_only -from [get_regs {u_target_frame_bridge/S_start_nonce[*] u_target_frame_bridge/S_start_frame_id[*] u_target_frame_bridge/S_start_effect_config[*] u_target_frame_bridge/S_start_motion_mode u_target_frame_bridge/S_start_color_mode[*] u_target_frame_bridge/S_start_valid}] -to [get_regs {u_target_frame_bridge/S_slot*}] 20.000
set_max_delay -datapath_only -from [get_regs {u_target_frame_bridge/S_result_payload[*]}] -to [get_regs {u_target_frame_bridge/S_slot* u_target_frame_bridge/S_last_result_payload[*]}] 20.000
set_max_delay -datapath_only -from [get_regs {u_target_frame_bridge/S_read_payload[*]}] -to [get_regs {u_target_frame_bridge/O_*}] 13.000

# K2 selects detection only at a camera frame boundary.
set_false_path -from [get_regs {u_detection_mode_control/O_detection_mode[*]}] -to [get_regs {u_isp_top/u_target_detect_switch/color_meta[*]}]
# SW1 is sampled by the first HDMI synchronizer; the second stage remains timed.
set_false_path -from [get_ports {I_latency_switch}] -to [get_regs {u_hdmi_mixer/latency_switch$show_meta}]
# Appended to candidate SDC by prepare_handfixed_project.py only when CNN is
# enabled. Base video projects must not constrain nonexistent CNN endpoints.
set_false_path -from [get_ports {I_resnet_uart_rx}] -to [get_regs -nowarn {*u_handcnn/uart/rx_meta}]
# Exclude only the first asynchronous stages. The always-present key endpoint
# keeps this collection valid when constant display enable removes enable_meta.
set_false_path -from [get_ports {I_param_key_n I_fruit_switch}] -to [get_regs -nowarn {*u_handcnn/key_control/key_meta u_hdmi_mixer/cnn_visibility$enable_meta}]
set_false_path -from [get_regs -nowarn {*u_status_cdc/req_toggle *u_hand_box_cdc/req_toggle}] -to [get_regs -nowarn {*u_status_cdc/req_meta *u_hand_box_cdc/req_meta}]
set_false_path -from [get_regs -nowarn {*u_status_cdc/ack_toggle *u_hand_box_cdc/ack_toggle}] -to [get_regs -nowarn {*u_status_cdc/ack_meta *u_hand_box_cdc/ack_meta}]
set_max_delay -datapath_only -from [get_regs -nowarn {*u_status_cdc/payload_hold[*] *u_hand_box_cdc/payload_hold[*]}] -to [get_regs -nowarn {*u_status_cdc/O_dst_data[*] *u_hand_box_cdc/O_dst_data[*]}] 13.000

# HX711 DOUT is asynchronous; only its first synchronizer stage is excluded.
set_false_path -from [get_ports {I_hx711_dout}] -to [get_regs -nowarn {*u_checkout/u_adc/dout_meta}]
set_false_path -from [get_ports {I_fruit_switch}] -to [get_regs -nowarn {*u_checkout/u_tare/key_meta *u_checkout/u_cal/key_meta *u_detection_mode_control/key_meta}]
