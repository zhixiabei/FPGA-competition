# Optional alternative for an installed ModelSim/Questa.
# In its Transcript: cd D:/vivado_work/anlogic_edge_osd/sim
#                   do run_modelsim.do
set sim_dir [file dirname [file normalize [info script]]]
file mkdir [file join $sim_dir out_modelsim]
cd [file join $sim_dir out_modelsim]
onerror {quit -code 1 -force}
if {![file isdirectory work]} {vlib work}
vmap work work
vlog -sv ../../user_source/hdl_source/isp/edge_detect_96.v ../tb_edge_detect.sv
vsim -voptargs=+acc work.tb_edge_detect
add wave sim:/tb_edge_detect/clk sim:/tb_edge_detect/rst_n
add wave sim:/tb_edge_detect/in_valid sim:/tb_edge_detect/in_user sim:/tb_edge_detect/in_last
add wave -radix hexadecimal sim:/tb_edge_detect/in_data
add wave sim:/tb_edge_detect/out_valid sim:/tb_edge_detect/out_user sim:/tb_edge_detect/out_last
add wave -radix hexadecimal sim:/tb_edge_detect/out_data
add wave -radix unsigned sim:/tb_edge_detect/frame_id sim:/tb_edge_detect/dut/x_grp sim:/tb_edge_detect/dut/y_pos
onfinish stop
run -all
