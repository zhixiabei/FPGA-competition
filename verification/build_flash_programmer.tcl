set root [file normalize [file join [file dirname [info script]] ..]]
set work $root/build/flash_model/programmer
file mkdir $work
cd $work
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project $work/project.al -single_run
    load_run_param -run syn_1
    commit_param -step design
    elaborate -top fruit_flash_program_top
    read_adc $root/verification/flash_programmer.adc
    read_sdc $root/verification/flash_programmer.sdc
    commit_param -step rtl
    optimize_rtl
    report_area -file programmer_rtl.area
    commit_param -step gate
    optimize_gate -packarea programmer_gate.area
    legalize_phy_inst
    load_run_param -run phy_1
    set_param route fix_hold on
    commit_param -step place
    place
    commit_param -step route
    route
    update_timing -mode final
    report_timing_summary -file programmer_pr.timing
    report_area -io_info -file programmer_phy.area
    export_db programmer_pr.db
    set f [open programmer_pr.timing r];set timing [read $f];close $f
    foreach kind {SWNS HWNS} {
        if {![regexp "$kind: *(-?\[0-9.\]+)ns" $timing unused slack] || $slack<0} {error "$kind timing failed"}
    }
    commit_param -step bitgen
    bitgen -bit fruit_flash_programmer.bit
    puts "FRUIT_FLASH_PROGRAMMER_BUILD_PASS"
} detail]} {puts stderr "FRUIT_FLASH_PROGRAMMER_BUILD_FAIL: $detail";exit 1}
exit 0
