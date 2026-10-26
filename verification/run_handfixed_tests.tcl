# Run from build/gesture/weights. Optional: set TEST_KIND system.
onerror {quit -code 1 -force}
onbreak {resume}
if {![info exists TEST_KIND]} {set TEST_KIND pipeline}
if {![info exists LIB_SUFFIX]} {set LIB_SUFFIX final}
set work fixed_${TEST_KIND}_${LIB_SUFFIX}_work
vlib $work
set lib E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p
vlog -work $work -sv $lib/ph1p_logic_dram.v $lib/ph1p_logic_dram64x8.v $lib/ph1p_phy_mslice.v $lib/ph1p_phy_dramhardcon.v $lib/ph1p_phy_gsr.v $lib/ph1p_logic_eram.v
vlog -work $work -sv E:/aaa/FPGA-competition-main/FPGA-competition-main/sim/resnet18_dsp_reference.sv E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/cnn/cnn_eram_byte_dp.v
vlog -work $work -sv E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/resnet18/resnet18_uart.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/resnet18/resnet18_weight_loader.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/resnet18/resnet18_memory_bridge.v
set h E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/handcnn
vlog -work $work -sv $h/handcnn_core.v $h/handcnn_snapshot.v $h/handcnn_normalize.v $h/handcnn_confidence.v handfixed_program.v handfixed_config.v
eval vlog -work $work -sv [glob E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/handfixed/*.v] tb_handfixed_${TEST_KIND}.sv
if {$TEST_KIND == "refresh"} {
    vlog -work $work -sv E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/camera_diag_cdc.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/display_effects_rgb888.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/gamma_lut_rgb888.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/hdmi_mixer.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/anlogic_logo_rom.v E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/osd_char_lib.v
}
vsim -onfinish stop -t ps ${work}.tb_handfixed_${TEST_KIND} ${work}.PH1P_PHY_GSR
run -all
quit -code 0 -force
