# Run only inside an isolated snapshot created by run_slice_candidate.ps1.
set root [pwd]
if {[catch {
    if {![file isfile source_sha256.csv] || ![file isfile system_gate.db]} {
        error "Expected an isolated, synthesized source snapshot"
    }
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project project.al -single_run
    import_db system_gate.db
    load_run_param -run phy_1
    commit_param -step place
    place
    update_timing -mode manhattan
    report_timing_summary -file system_place.timing
    commit_param -step route
    route
    update_timing -mode final
    report_timing_summary -file system_pr.timing
    report_area -io_info -file system_phy.area
    report_timing_status -file system_phy.ts
    check_timing -verbose -file constraint_health.timing
    export_db system_pr.db
    puts "SLICE_CANDIDATE_ROUTE_PASS"
} detail]} {
    puts stderr "SLICE_CANDIDATE_ROUTE_FAIL: $detail"
    exit 1
}
exit 0
