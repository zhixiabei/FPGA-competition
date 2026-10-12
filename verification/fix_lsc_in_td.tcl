# Run in the Tcl Console of the OPEN anlogic_edge_osd TD project:
# source D:/vivado_work/anlogic_edge_osd/verification/fix_lsc_in_td.tcl
# Close first because TD may save its old in-memory source list during close.
set lsc_fix_root [file normalize [file join [file dirname [info script]] ..]]
set lsc_fix_project [file join $lsc_fix_root td_project anlogic_edge_osd.al]
set lsc_fix_source ../user_source/hdl_source/isp/lsc_raw10_4x.v
foreach lsc_fix_command {close_project open_project reset_runs launch_runs} {
    if {[llength [info commands $lsc_fix_command]] == 0} {
        error "Open anlogic_edge_osd.al in TD before sourcing this script."
    }
}
if {![file isfile $lsc_fix_project] ||
    ![file isfile [file join $lsc_fix_root td_project $lsc_fix_source]]} {
    error "Required LSC source or project file is missing."
}

close_project
set lsc_fix_handle [open $lsc_fix_project r]
fconfigure $lsc_fix_handle -encoding utf-8
set lsc_fix_text [read $lsc_fix_handle]
close $lsc_fix_handle
set lsc_fix_tag "<File Path=\"$lsc_fix_source\">"
if {[string first $lsc_fix_tag $lsc_fix_text] < 0} {
    set lsc_fix_anchor {        </Verilog>}
    if {[string first $lsc_fix_anchor $lsc_fix_text] < 0} {
        error "Project has no Verilog source section; no file was modified."
    }
    file copy -force $lsc_fix_project [file join $lsc_fix_root verification lsc_before_gui_repair.log]
    set lsc_fix_entry "            $lsc_fix_tag\n                <FileInfo>\n                    <Attr Name=\"UsedInSyn\" Val=\"true\"/>\n                    <Attr Name=\"UsedInP&R\" Val=\"true\"/>\n                    <Attr Name=\"BelongTo\" Val=\"design_1\"/>\n                    <Attr Name=\"CompileOrder\" Val=\"64\"/>\n                </FileInfo>\n            </File>\n"
    set lsc_fix_text [string map [list $lsc_fix_anchor "$lsc_fix_entry$lsc_fix_anchor"] $lsc_fix_text]
    set lsc_fix_handle [open $lsc_fix_project w]
    fconfigure $lsc_fix_handle -encoding utf-8 -translation lf
    puts -nonewline $lsc_fix_handle $lsc_fix_text
    close $lsc_fix_handle
}
open_project $lsc_fix_project
puts "LSC_PROJECT_RELOADED_WITH_REQUIRED_SOURCE"

# Regenerate the synthesis input from the reloaded project. Keep run files.
reset_runs syn_1
launch_runs syn_1
puts "LSC_GUI_SYNTHESIS_STARTED: inspect syn_1 for the final result."
