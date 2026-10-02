# Execute the GUI-generated syn_1 .prj/settings with TD's actual DefaultFlow.
# This is an optional direct replay of the real GUI run's .prj and settings.
# Generate them with fix_video_mode_in_td.tcl before this check. When launching
# a multi-run project headlessly, import_device must precede open_project so
# the generated settings contain the correct device and package.
# Run only while no other synthesis task for this project is active.
set video_mode_check_root [file normalize [file join [file dirname [info script]] ..]]
set video_mode_run_dir [file join $video_mode_check_root td_project anlogic_edge_osd_Runs syn_1]
cd $video_mode_run_dir
if {[catch {
    set video_mode_prj_file [open [file join $video_mode_run_dir anlogic_edge_osd.prj] r]
    set video_mode_prj_text [read $video_mode_prj_file]
    close $video_mode_prj_file
    foreach video_mode_file {video_mode_control.v rgb_edge_switch_96.v} {
        if {[string first $video_mode_file $video_mode_prj_text] < 0} {
            error "Generated syn_1 project still omits $video_mode_file"
        }
    }
    source D:/TD/doc/scripts/DefaultFlow.tcl
    if {![file isfile [file join $video_mode_run_dir .opt_gate.end.f]]} {
        error "The actual syn_1 run did not complete Optimize Gate. Inspect its log."
    }
    puts "VIDEO_MODE_GUI_FLOW_PASS: generated syn_1 includes both modules and completes Optimize Gate."
} video_mode_check_error]} {
    puts stderr "VIDEO_MODE_GUI_FLOW_FAIL: $video_mode_check_error"
    exit 1
}
exit 0
