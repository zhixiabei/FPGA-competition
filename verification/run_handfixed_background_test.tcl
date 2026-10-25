onerror {quit -code 1 -force}
onbreak {resume}
vlib background_work
set lib E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p
vlog -work background_work -sv $lib/ph1p_logic_eram.v $lib/ph1p_phy_gsr.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/cnn/cnn_eram_byte_dp.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/handfixed/handfixed_background.v E:/aaa/FPGA-competition-main/FPGA-competition-main/sim/tb_handfixed_background.sv
vsim -onfinish stop background_work.tb_handfixed_background background_work.PH1P_PHY_GSR
run -all
quit -code 0 -force
