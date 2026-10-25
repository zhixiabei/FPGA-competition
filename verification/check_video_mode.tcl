# Check either real TD project without synthesis, place/route or bit generation.
set root [file normalize [file join [file dirname [info script]] ..]]
cd [file join $root verification]
set project anlogic_edge_osd
set top design_top_wrapper
if {[info exists env(VIDEO_MODE_CAPTURE)] && $env(VIDEO_MODE_CAPTURE) eq "1"} {
    set project anlogic_sc520_capture
    set top sc520_capture_top
}
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project [file join $root td_project ${project}.al] -single_run
    elaborate -top $top
    read_adc [file join $root user_source constraints_source pin.adc]
    read_sdc [file join $root td_project ${project}.sdc]
    puts "VIDEO_MODE_ELABORATION_PASS: $project"
} detail]} {
    puts stderr "VIDEO_MODE_ELABORATION_FAIL: $project: $detail"
    exit 1
}
exit 0
