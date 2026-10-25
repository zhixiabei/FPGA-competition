onerror {quit -code 1 -force}
onbreak {resume}
vlib key_work
vlog -work key_work -sv E:/aaa/FPGA-competition-main/FPGA-competition-main/user_source/hdl_source/handfixed/handfixed_key_control.v E:/aaa/FPGA-competition-main/FPGA-competition-main/sim/tb_handfixed_key_control.sv
vsim -onfinish stop key_work.tb_handfixed_key_control
run -all
quit -code 0 -force
