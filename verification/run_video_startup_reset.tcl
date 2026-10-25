# Optional manual regression. This script compiles simulation sources only;
# it is not invoked automatically by project builds or by this source change.
onerror {quit -code 1 -force}
onbreak {resume}
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build video_startup_checks]
file mkdir $out
cd $out
vlib video_startup
set lib E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p
vlog -work video_startup -sv $lib/ph1p_phy_gsr.v $lib/ph1p_logic_eram.v \
    $root/user_source/ip_source/w128_d512_fifo/w128_d512_fifo.v \
    $root/user_source/ip_source/w128_d512_fifo/soft_fifo_al_4057d6b76aa6.v \
    $root/user_source/ip_source/w155_d512_fifo/w155_d512_fifo.v \
    $root/user_source/ip_source/w155_d512_fifo/soft_fifo_al_f58e8b3e1f3d.v \
    $root/user_source/hdl_source/video_out.v \
    $root/user_source/hdl_source/mc_to_user_interface.v \
    $root/sim/tb_video_startup_reset.sv
vsim -onfinish stop -t ps video_startup.tb_video_startup_reset video_startup.PH1P_PHY_GSR
run -all
quit -code 0 -force
