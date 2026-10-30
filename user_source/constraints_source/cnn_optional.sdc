# Appended to candidate SDC by prepare_handfixed_project.py only when CNN is
# enabled. Base video projects must not constrain nonexistent CNN endpoints.
set_false_path -from [get_ports {I_resnet_uart_rx}] -to [get_regs -nowarn {*u_handcnn/uart/rx_meta *u_handcnn/flash_model$status_uart/uart/rx_meta}]
# Exclude only the first asynchronous stages. The always-present key endpoint
# keeps this collection valid when constant display enable removes enable_meta.
set_false_path -from [get_ports {I_param_key_n I_fruit_switch}] -to [get_regs -nowarn {*u_handcnn/key_control/key_meta u_hdmi_mixer/cnn_visibility$enable_meta}]
set_false_path -from [get_regs -nowarn {*u_status_cdc/req_toggle *u_hand_box_cdc/req_toggle}] -to [get_regs -nowarn {*u_status_cdc/req_meta *u_hand_box_cdc/req_meta}]
set_false_path -from [get_regs -nowarn {*u_status_cdc/ack_toggle *u_hand_box_cdc/ack_toggle}] -to [get_regs -nowarn {*u_status_cdc/ack_meta *u_hand_box_cdc/ack_meta}]
set_max_delay -datapath_only -from [get_regs -nowarn {*u_status_cdc/payload_hold[*] *u_hand_box_cdc/payload_hold[*]}] -to [get_regs -nowarn {*u_status_cdc/O_dst_data[*] *u_hand_box_cdc/O_dst_data[*]}] 13.000
