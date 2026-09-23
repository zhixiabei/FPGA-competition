# Log only scalar ports/counters, not large image arrays and RAM contents.
log_wave /tb_edge_detect/clk /tb_edge_detect/rst_n
log_wave /tb_edge_detect/in_valid /tb_edge_detect/in_user /tb_edge_detect/in_last /tb_edge_detect/in_data
log_wave /tb_edge_detect/out_valid /tb_edge_detect/out_user /tb_edge_detect/out_last /tb_edge_detect/out_data
log_wave /tb_edge_detect/frame_id /tb_edge_detect/dut/x_grp /tb_edge_detect/dut/y_pos
run all
quit
