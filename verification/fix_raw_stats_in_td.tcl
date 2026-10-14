# Run in the Tcl Console of the OPEN anlogic_edge_osd TD project:
# source D:/vivado_work/anlogic_edge_osd/verification/fix_raw_stats_in_td.tcl
# Close first: TD can otherwise overwrite the repaired disk source list with
# its stale in-memory list on save/close. Only synthesis is relaunched.
set raw_stats_fix_root [file normalize [file join [file dirname [info script]] ..]]
set raw_stats_fix_project [file join $raw_stats_fix_root td_project anlogic_edge_osd.al]
set raw_stats_fix_sources {
    ../user_source/hdl_source/isp/raw_region_stats.v
    ../user_source/hdl_source/raw_stats_osd.v
}
foreach raw_stats_fix_command {close_project open_project reset_runs launch_runs} {
    if {[llength [info commands $raw_stats_fix_command]] == 0} {
        error "Open anlogic_edge_osd.al in TD before sourcing this script."
    }
}
if {![file isfile $raw_stats_fix_project]} {
    error "The main TD project file is missing."
}
foreach raw_stats_fix_source $raw_stats_fix_sources {
    if {![file isfile [file join $raw_stats_fix_root td_project $raw_stats_fix_source]]} {
        error "Required RAW statistics source is missing: $raw_stats_fix_source"
    }
}

close_project
set raw_stats_fix_handle [open $raw_stats_fix_project r]
fconfigure $raw_stats_fix_handle -encoding utf-8
set raw_stats_fix_text [read $raw_stats_fix_handle]
close $raw_stats_fix_handle
set raw_stats_fix_anchor {        </Verilog>}
if {[string first $raw_stats_fix_anchor $raw_stats_fix_text] < 0} {
    error "Project has no Verilog source section; no file was modified."
}
set raw_stats_fix_order 101
set raw_stats_fix_entries ""
foreach raw_stats_fix_source $raw_stats_fix_sources {
    set raw_stats_fix_tag "<File Path=\"$raw_stats_fix_source\">"
    if {[string first $raw_stats_fix_tag $raw_stats_fix_text] < 0} {
        append raw_stats_fix_entries "            $raw_stats_fix_tag\n                <FileInfo>\n                    <Attr Name=\"UsedInSyn\" Val=\"true\"/>\n                    <Attr Name=\"UsedInP&R\" Val=\"true\"/>\n                    <Attr Name=\"BelongTo\" Val=\"design_1\"/>\n                    <Attr Name=\"CompileOrder\" Val=\"$raw_stats_fix_order\"/>\n                </FileInfo>\n            </File>\n"
    }
    incr raw_stats_fix_order
}
if {$raw_stats_fix_entries ne ""} {
    # Keep a unique recovery copy of the project configuration, not run data.
    set raw_stats_fix_backup [file join $raw_stats_fix_root verification "raw_stats_before_gui_repair_[clock clicks].log"]
    file copy $raw_stats_fix_project $raw_stats_fix_backup
    set raw_stats_fix_text [string map [list $raw_stats_fix_anchor "$raw_stats_fix_entries$raw_stats_fix_anchor"] $raw_stats_fix_text]
    set raw_stats_fix_handle [open $raw_stats_fix_project w]
    fconfigure $raw_stats_fix_handle -encoding utf-8 -translation lf
    puts -nonewline $raw_stats_fix_handle $raw_stats_fix_text
    close $raw_stats_fix_handle
}
open_project $raw_stats_fix_project
puts "RAW_STATS_PROJECT_RELOADED_WITH_REQUIRED_SOURCES"
reset_runs syn_1
launch_runs syn_1
puts "RAW_STATS_GUI_SYNTHESIS_STARTED: inspect syn_1 for the final result."
