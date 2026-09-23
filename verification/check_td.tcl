# Run from this directory with: D:/TD/bin/td_commands_prompt.exe check_td.tcl
# Load the actual GUI project and check the merged RTL hierarchy.
set check_root [file dirname [file normalize [info script]]]
cd $check_root
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project ../td_project/anlogic_edge_osd.al -single_run
    elaborate -top design_top_wrapper
    puts "MERGED_PROJECT_ELABORATION_PASS"
} detail]} {
    puts stderr "MERGED_PROJECT_ELABORATION_FAIL: $detail"
    exit 1
}
exit 0
