# Run in the normal phy_1 directory, applying project parameters after DB import.
set congestion_project_dir [file dirname [file normalize [info script]]]
set congestion_project_file [file join $congestion_project_dir anlogic_edge_osd.al]
set congestion_run_dir [file join $congestion_project_dir anlogic_edge_osd_Runs phy_1]
set congestion_gate_db [file join $congestion_project_dir anlogic_edge_osd_Runs syn_1 anlogic_edge_osd_gate.db]
cd $congestion_run_dir

proc congestion_mark {name contents} {
    set channel [open $name w]
    puts $channel $contents
    close $channel
}

set congestion_stage opt_place
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project $congestion_project_file -single_run
    import_db $congestion_gate_db
    load_run_param -run phy_1
    set_param place seed 1
    set_param route effort normal
    set_param route timing on
    set_param route fix_hold on
    commit_param -step place
    commit_param -step route
    puts "CONGESTIONHIGH_PARAMETERS_LOADED seed=1 route_effort=normal timing=on fix_hold=on"
    congestion_mark .opt_place.begin.f [format {<ProcessHandle><Process Pid="%s"/></ProcessHandle>} [pid]]
    place
    update_timing -mode manhattan
    report_timing_summary -file anlogic_edge_osd_place.timing
    report_area -io_info -file anlogic_edge_osd_phy.area
    report_qor -step place -file place.qor
    report_clock_utilization -file place_clock_utilization.txt
    flow_status -file place_flow.status
    export_db anlogic_edge_osd_place.db
    congestion_mark .opt_place.end.f {}
    set congestion_stage opt_route
    congestion_mark .opt_route.begin.f [format {<ProcessHandle><Process Pid="%s"/></ProcessHandle>} [pid]]
    if {[catch {route} congestion_route_error congestion_route_options]} {
        puts stderr "ROUTE_FAILURE_DIAGNOSTICS_BEGIN"
        foreach diagnostic {
            {export_db failed_route.db}
            {report_congestion -step route -line 100}
            {report_route_status -drc -file failed_route.status}
        } {
            if {[catch {eval $diagnostic} detail]} {
                puts stderr "ROUTE_DIAGNOSTIC_UNAVAILABLE $diagnostic: $detail"
            }
        }
        puts stderr "ROUTE_FAILURE_DIAGNOSTICS_END"
        return -options $congestion_route_options $congestion_route_error
    }
    update_timing -mode final
    report_timing_summary -file anlogic_edge_osd_pr.timing
    report_timing_status -file anlogic_edge_osd_phy.ts
    report_qor -step route -file route.qor
    report_area -io_info -file anlogic_edge_osd_phy.area
    report_timing_exception -file anlogic_edge_osd_exception.timing
    check_timing -verbose -file constraint_health.timing
    report_clock_utilization -file route_clock_utilization.txt
    flow_status -file route_flow.status
    export_db anlogic_edge_osd_pr.db
    report_route_status -file anlogic_edge_osd_route.status
    congestion_mark .opt_route.end.f {}
    puts "CONGESTIONHIGH_FLOW_COMPLETE_PENDING_ACCEPTANCE"
} congestion_message]} {
    congestion_mark .$congestion_stage.error.f $congestion_message
    puts stderr "CONGESTIONHIGH_FLOW_FAIL: $congestion_message"
    puts stderr $::errorInfo
    exit 1
}
exit 0
