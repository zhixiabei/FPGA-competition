# Generate programming files from the existing routed database only.
set bitgen_project_dir [file dirname [file normalize [info script]]]
cd [file join $bitgen_project_dir anlogic_edge_osd_Runs phy_1]

if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project anlogic_edge_osd.prj -noanalyze
    import_db anlogic_edge_osd_pr.db
    report_route_status -file bitgen_route.status
    update_timing -mode final
    report_timing_summary -file bitgen_final.timing
    report_timing_status -file bitgen_final.ts
    report_qor -step route -file bitgen.qor

    set fd [open bitgen_final.timing r]
    set timing_text [read $fd]
    close $fd
    foreach metric {SWNS HWNS} {
        if {![regexp [format {%s: *(-?[0-9.]+)ns} $metric] $timing_text unused slack] || $slack < 0} {
            error "Routed timing failed: $metric"
        }
    }
    commit_param -step bitgen
    set_param bitgen compress on
    bitgen -bit anlogic_edge_osd.bit
    export_bitgen_param -file .bitgen_param.f
    puts "ROUTED_BITGEN_COMPLETE"
} bitgen_error]} {
    puts stderr "ROUTED_BITGEN_FAILED: $bitgen_error"
    puts stderr $::errorInfo
    exit 1
}
exit 0
