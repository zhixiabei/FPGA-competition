# Run in the Tcl Console of the OPEN anlogic_edge_osd TD project:
# source D:/vivado_work/anlogic_edge_osd/verification/fix_video_mode_in_td.tcl
# Close the old in-memory project BEFORE repairing the file, then reopen it.
# This ordering prevents close/save from overwriting the repair again.
set video_mode_root [file normalize [file join [file dirname [info script]] ..]]
set video_mode_project [file join $video_mode_root td_project anlogic_edge_osd.al]
set video_mode_sources {../user_source/hdl_source/video_mode_control.v ../user_source/hdl_source/isp/rgb_edge_switch_96.v}
foreach video_mode_command {close_project open_project reset_runs launch_runs} {
    if {[llength [info commands $video_mode_command]] == 0} {
        error "Open anlogic_edge_osd.al in TD project mode before sourcing this script."
    }
}
foreach video_mode_source $video_mode_sources {
    if {![file isfile [file join $video_mode_root td_project $video_mode_source]]} {
        error "Required source does not exist: $video_mode_source"
    }
}

if {![file isfile $video_mode_project]} {
    error "Required project does not exist: $video_mode_project"
}

# TD may save its stale source list during close. Repair only AFTER it closes.
close_project
set video_mode_handle [open $video_mode_project r]
fconfigure $video_mode_handle -encoding utf-8
set video_mode_text [read $video_mode_handle]
close $video_mode_handle
if {[string first {</Verilog>} $video_mode_text] < 0} {
    error "Project has no Verilog source section; no file was modified."
}
file copy -force $video_mode_project [file join $video_mode_root verification video_mode_before_gui_repair.log]
set video_mode_order 56
foreach video_mode_source $video_mode_sources {
    set video_mode_tag "<File Path=\"$video_mode_source\">"
    if {[string first $video_mode_tag $video_mode_text] < 0} {
        set video_mode_entry "            $video_mode_tag\n                <FileInfo>\n                    <Attr Name=\"UsedInSyn\" Val=\"true\"/>\n                    <Attr Name=\"UsedInP&R\" Val=\"true\"/>\n                    <Attr Name=\"BelongTo\" Val=\"design_1\"/>\n                    <Attr Name=\"CompileOrder\" Val=\"$video_mode_order\"/>\n                </FileInfo>\n            </File>\n"
        set video_mode_text [string map [list {        </Verilog>} "$video_mode_entry        </Verilog>"] $video_mode_text]
    }
    incr video_mode_order
}
# Old hierarchy discovery marked the edge engine unreachable when its wrapper
# was missing. Clear that flag on the three mode/edge files only.
foreach video_mode_source [concat $video_mode_sources {../user_source/hdl_source/isp/edge_detect_96.v}] {
    set video_mode_begin [string first "<File Path=\"$video_mode_source\">" $video_mode_text]
    set video_mode_end [string first {</File>} $video_mode_text $video_mode_begin]
    if {$video_mode_begin < 0 || $video_mode_end < 0} {
        error "Required project entry missing: $video_mode_source"
    }
    incr video_mode_end 6
    set video_mode_block [string range $video_mode_text $video_mode_begin $video_mode_end]
    regsub -all {\s*<Attr Name="AutoExcluded" Val="true"/>} $video_mode_block {} video_mode_block
    set video_mode_text [string replace $video_mode_text $video_mode_begin $video_mode_end $video_mode_block]
}
regsub {(<Run Name="syn_1"[^>]*useDefaultScript=")false"} $video_mode_text {\1true"} video_mode_text
set video_mode_handle [open $video_mode_project w]
fconfigure $video_mode_handle -encoding utf-8 -translation lf
puts -nonewline $video_mode_handle $video_mode_text
close $video_mode_handle
open_project $video_mode_project
puts "VIDEO_MODE_PROJECT_RELOADED_WITH_REQUIRED_SOURCES"

# Reset status without -f; do not delete the run directory.
# launch_runs regenerates the .prj/settings from the updated current project.
reset_runs syn_1
launch_runs syn_1
puts "VIDEO_MODE_GUI_SYNTHESIS_STARTED: inspect syn_1 for the final result."
