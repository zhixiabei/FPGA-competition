# Run from this directory with: D:/TD/bin/td_commands_prompt.exe synth_td.tcl
# Source-level synthesis check; place/route and hardware validation are separate.
set check_root [file dirname [file normalize [info script]]]
cd $check_root
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project ../td_project/anlogic_edge_osd.al -single_run
    elaborate -top design_top_wrapper
    read_adc ../user_source/constraints_source/pin.adc
    read_ip_adc -ip ddr2 -file ../user_source/hdl_source/ph1p35_ddr/ddr2/src/adc/ddr2.adc
    read_sdc ../td_project/anlogic_edge_osd.sdc
    read_sdc -ip ddr2 ../user_source/hdl_source/ph1p35_ddr/ddr2/src/sdc/ddr2.sdc
    read_sdc -ip w128_d512_fifo ../user_source/ip_source/w128_d512_fifo/w128_d512_fifo.tcl
    commit_param -step rtl
    optimize_rtl
    report_area -file merged_rtl.area
    commit_param -step gate
    optimize_gate -packarea merged_gate.area
    legalize_phy_inst
    update_timing
    report_timing_summary -file merged_gate.timing
    puts "MERGED_PROJECT_SYNTHESIS_PASS"
} detail]} {
    puts stderr "MERGED_PROJECT_SYNTHESIS_FAIL: $detail"
    exit 1
}
exit 0
