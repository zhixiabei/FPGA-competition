set sim_dir [file dirname [file normalize [info script]]]
open_wave_database [file join $sim_dir out edge.wdb]
create_wave_config
add_wave /tb_edge_detect/clk /tb_edge_detect/rst_n
add_wave /tb_edge_detect/in_valid /tb_edge_detect/in_user /tb_edge_detect/in_last
add_wave -radix hex /tb_edge_detect/in_data
add_wave /tb_edge_detect/out_valid /tb_edge_detect/out_user /tb_edge_detect/out_last
add_wave -radix hex /tb_edge_detect/out_data
add_wave -radix unsigned /tb_edge_detect/frame_id /tb_edge_detect/dut/x_grp /tb_edge_detect/dut/y_pos
# See reset and the first few line transfers initially.
catch {set_property DISPLAY_LIMIT 3000 [current_wave_config]}
