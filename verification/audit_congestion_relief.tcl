# Invoke with CONGESTION_SNAPSHOT and CONGESTION_AUDIT_OUTPUT set by the caller.
# Database import is read-only; reports describe this snapshot, never a live router.
if {![info exists ::env(CONGESTION_SNAPSHOT)] ||
    ![info exists ::env(CONGESTION_AUDIT_OUTPUT)]} {
    puts stderr "Set CONGESTION_SNAPSHOT and CONGESTION_AUDIT_OUTPUT"
    exit 1
}
set snapshot [file normalize $::env(CONGESTION_SNAPSHOT)]
set output [file normalize $::env(CONGESTION_AUDIT_OUTPUT)]
set database system_gate.db
if {[info exists ::env(CONGESTION_AUDIT_DATABASE)]} {
    set database $::env(CONGESTION_AUDIT_DATABASE)
}
if {$database ni {system_gate.db system_place.db system_pr.db}} {
    puts stderr "Unsupported audit database"
    exit 1
}
file mkdir $output
cd $output
set congestion_database_path [file join $snapshot $database]
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    puts "AUDIT_DATABASE $congestion_database_path"
    import_db $congestion_database_path
    report_area -file area.rpt
    set cnn {handcnn_recognition$u_handcnn/core}
    set detector {u_isp_top/u_target_detect_switch/u_red/gen_single_shape$u_engine}
    for {set bank 0} {$bank < 4} {incr bank} {
        foreach signal {valid first is_padding {offset[0]} {offset[1]} {offset[2]}} {
            set name [format {%s/activation_banks[%d]$%s} $cnn $bank $signal]
            if {[llength [get_regs $name]] != 1} {
                error "Missing unique CNN bank register: $name"
            }
            puts "PRESERVED_CNN_REGISTER $name"
        }
    }
    for {set bank 0} {$bank < 5} {incr bank} {
        foreach signal {valid final_row} {
            set name [format {%s/gen_row_bank[%d]$%s} $detector $bank $signal]
            if {[llength [get_regs $name]] != 1} {
                error "Missing unique detector bank register: $name"
            }
            puts "PRESERVED_DETECTOR_REGISTER $name"
            report_nets [get_nets $name] -connection -pin_display_limit 8
        }
    }
    puts "CNN_NETS_BEGIN"
    report_nets [get_nets [format {%s/*} $cnn]]
    puts "CNN_NETS_END"
    puts "DETECTOR_NETS_BEGIN"
    report_nets [get_nets [format {%s/*} $detector]]
    puts "DETECTOR_NETS_END"
    puts "CONGESTION_PRESERVATION_AUDIT_PASS cnn=24 detector=10"
} message]} {
    puts stderr "CONGESTION_PRESERVATION_AUDIT_FAIL: $message"
    puts stderr $::errorInfo
    exit 1
}
exit 0
