# Run with D:/TD/bin/td_commands_prompt.exe verification/synth_video_mode.tcl
# Uses the actual main project and the standard TD synthesis stages.
# Reports have a separate prefix; existing baseline reports are preserved.
# This does not modify the open GUI session or generate a bitstream.
set root [file normalize [file join [file dirname [info script]] ..]]
cd [file join $root verification]
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project [file join $root td_project anlogic_edge_osd.al] -single_run
    load_run_param -run syn_1
    commit_param -step design
    elaborate -top design_top_wrapper
    read_adc [file join $root user_source constraints_source pin.adc]
    read_ip_adc -ip ddr2 -file [file join $root user_source hdl_source ph1p35_ddr ddr2 src adc ddr2.adc]
    read_sdc [file join $root td_project anlogic_edge_osd.sdc]
    read_sdc -ip ddr2 [file join $root user_source hdl_source ph1p35_ddr ddr2 src sdc ddr2.sdc]
    read_sdc -ip w128_d512_fifo [file join $root user_source ip_source w128_d512_fifo w128_d512_fifo.tcl]
    puts "VIDEO_MODE_READ_DESIGN_PASS"

    commit_param -step rtl
    insert_debugger
    optimize_rtl
    report_area -file video_mode_rtl.area
    puts "VIDEO_MODE_OPT_RTL_PASS"

    commit_param -step gate
    optimize_gate -packarea video_mode_gate.area
    legalize_phy_inst
    update_timing
    report_timing_summary -file video_mode_gate.timing
    export_db video_mode_gate.db
    puts "VIDEO_MODE_SYNTHESIS_PASS"
} detail]} {
    puts stderr "VIDEO_MODE_SYNTHESIS_FAIL: $detail"
    exit 1
}
exit 0
