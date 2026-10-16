# Shared full TD flow. The small entry scripts select the GUI project to build.
set source_root [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $source_root build td $sc520_project]
file mkdir $build_dir
# TD resolves the .al source paths against the process working directory.
# Keep the same sibling depth as td_project; place deliverables in build_dir.
cd [file join $source_root verification]
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project [file join $source_root td_project ${sc520_project}.al] -single_run
    load_run_param -run syn_1
    elaborate -top $sc520_top
    read_adc [file join $source_root user_source constraints_source pin.adc]
    read_ip_adc -ip ddr2 -file [file join $source_root user_source hdl_source ph1p35_ddr ddr2 src adc ddr2.adc]
    read_sdc [file join $source_root td_project ${sc520_project}.sdc]
    read_sdc -ip ddr2 [file join $source_root user_source hdl_source ph1p35_ddr ddr2 src sdc ddr2.sdc]
    read_sdc -ip w128_d512_fifo [file join $source_root user_source ip_source w128_d512_fifo w128_d512_fifo.tcl]
    commit_param -step rtl
    optimize_rtl
    report_area -file [file join $build_dir ${sc520_project}_rtl.area]
    commit_param -step gate
    optimize_gate -packarea [file join $build_dir ${sc520_project}_gate.area]
    legalize_phy_inst
    update_timing
    report_timing_summary -file [file join $build_dir ${sc520_project}_gate.timing]
    load_run_param -run phy_1
    commit_param -step place
    place
    update_timing -mode manhattan
    report_timing_summary -file [file join $build_dir ${sc520_project}_place.timing]
    commit_param -step route
    route
    update_timing -mode final
    report_timing_summary -file [file join $build_dir ${sc520_project}_pr.timing]
    report_timing_status -file [file join $build_dir ${sc520_project}_phy.ts]
    report_area -io_info -file [file join $build_dir ${sc520_project}_phy.area]
    report_clock_utilization -file [file join $build_dir clock_utilization.txt]
    export_db [file join $build_dir ${sc520_project}_pr.db]
    commit_param -step bitgen
    bitgen -bit [file join $build_dir ${sc520_project}.bit]
    puts "SC520_BUILD_PASS: $sc520_project"
    puts "Internal build output: $build_dir"
    puts "Use build_firmware.cmd to update firmware/anlogic_edge_osd.bit."
} detail]} {
    puts stderr "SC520_BUILD_FAIL: $sc520_project: $detail"
    exit 1
}
exit 0
