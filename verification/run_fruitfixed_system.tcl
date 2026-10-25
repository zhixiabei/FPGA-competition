onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib fruit_system_ase_work
set lib E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p
set candidate build/fruit/td/sources/candidate
if {[info exists env(FRUITFIXED_TEST_PROJECT)]} {
    set candidate $env(FRUITFIXED_TEST_PROJECT)/sources/candidate
}
vlog -work fruit_system_ase_work -sv $lib/ph1p_logic_dram.v $lib/ph1p_logic_dram64x8.v $lib/ph1p_phy_mslice.v $lib/ph1p_phy_dramhardcon.v $lib/ph1p_phy_gsr.v $lib/ph1p_logic_eram.v
vlog -work fruit_system_ase_work -sv sim/resnet18_dsp_reference.sv user_source/hdl_source/cnn/cnn_eram_byte_dp.v
vlog -work fruit_system_ase_work -sv user_source/hdl_source/resnet18/resnet18_uart.v user_source/hdl_source/resnet18/resnet18_weight_loader.v
vlog -work fruit_system_ase_work -sv $candidate/fruitcnn128_core.v user_source/hdl_source/handcnn/handcnn_snapshot.v $candidate/handcnn_normalize.v
vlog -work fruit_system_ase_work -sv $candidate/handcnn_confidence.v $candidate/handfixed_config.v $candidate/handfixed_program.v
vlog -work fruit_system_ase_work -sv $candidate/handfixed_key_control.v $candidate/handfixed_background.v $candidate/handfixed_preprocess.v $candidate/fruitfixed_decode.v $candidate/fruitfixed_result_filter.v $candidate/fruitfixed_system.v sim/tb_fruitfixed_system.sv
vsim -onfinish exit -t ps fruit_system_ase_work.tb_fruitfixed_system fruit_system_ase_work.PH1P_PHY_GSR
run -all
quit -code 0 -force
