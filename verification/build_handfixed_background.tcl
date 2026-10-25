# Full physical flow for the frozen fixed-ROI KEY4 background-reference candidate.
# User requested place/route and bit generation. Does not program hardware.
set repository_root [file normalize [file join [file dirname [info script]] ..]]
set stable_root [file join $repository_root build gesture td]
if {[info exists env(HANDFIXED_BUILD_PROJECT)]} {set stable_root [file normalize $env(HANDFIXED_BUILD_PROJECT)]}
set bit_name anlogic_edge_osd.bit
if {[info exists env(FRUITFIXED_BUILD)] && $env(FRUITFIXED_BUILD) eq "1"} {
    set bit_name fruitfixed_candidate.bit
}
cd $stable_root
set physical [file join $stable_root handfixed_candidate_Runs phy_1]
set release [file join $repository_root td_project anlogic_edge_osd_Runs best_result]
set report_release [file join $stable_root handfixed_candidate_Runs best_result]
file mkdir $physical
if {[file exists [file join $release $bit_name]]} {
    puts stderr "HANDFIXED_BACKGROUND_BUILD_FAIL: existing final bit; use the saved route DB for a deliberate rebuild"
    exit 1
}
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project handfixed_candidate.al -single_run
    load_run_param -run syn_1
    commit_param -step design
    elaborate -top design_top_wrapper
    read_adc $stable_root/sources/user_source/constraints_source/pin.adc
    read_ip_adc -ip ddr2 -file $stable_root/sources/user_source/hdl_source/ph1p35_ddr/ddr2/src/adc/ddr2.adc
    read_sdc $stable_root/sources/td_project/anlogic_edge_osd.sdc
    read_sdc -ip ddr2 $stable_root/sources/user_source/hdl_source/ph1p35_ddr/ddr2/src/sdc/ddr2.sdc
    read_sdc -ip w128_d512_fifo $stable_root/sources/user_source/ip_source/w128_d512_fifo/w128_d512_fifo.tcl
    commit_param -step rtl
    optimize_rtl
    report_area -file $physical/handfixed_candidate_rtl.area
    set_param -run syn_1 gate map_mode area_prior
    set_param -run syn_1 gate pack_effort high
    load_run_param -run syn_1
    commit_param -step gate
    optimize_gate -packarea $physical/handfixed_candidate_gate.area
    legalize_phy_inst
    update_timing
    report_timing_summary -file $physical/handfixed_candidate_gate.timing
    export_db $physical/handfixed_candidate_gate.db
    puts "HANDFIXED_BACKGROUND_GATE_PASS"

    set_param -run phy_1 route fix_hold on
    load_run_param -run phy_1
    commit_param -step place
    place
    update_timing -mode manhattan
    report_timing_summary -file $physical/handfixed_candidate_place.timing
    report_area -io_info -file $physical/handfixed_candidate_place.area
    export_db $physical/handfixed_candidate_place.db
    puts "HANDFIXED_BACKGROUND_PLACE_PASS"

    commit_param -step route
    route
    update_timing -mode final
    report_timing_summary -file $physical/handfixed_candidate_pr.timing
    report_timing_status -file $physical/handfixed_candidate_phy.ts
    check_timing -verbose -file $physical/handfixed_candidate_constraints.timing
    report_timing_exception -file $physical/handfixed_candidate_exception.timing
    report_area -io_info -file $physical/handfixed_candidate_phy.area
    report_clock_utilization -file $physical/route_clock_utilization.txt
    export_db $physical/handfixed_candidate_pr.db
    puts "HANDFIXED_BACKGROUND_ROUTE_PASS"

    set handle [open $physical/handfixed_candidate_pr.timing r]
    set timing [read $handle]
    close $handle
    foreach kind {SWNS HWNS} {
        set pattern [format {%s: *([-0-9.]+)ns} $kind]
        if {![regexp $pattern $timing unused slack] || $slack < 0} {
            error "Final $kind timing failed; route DB and reports retained"
        }
    }
    set handle [open $physical/handfixed_candidate_constraints.timing r]
    set health [read $handle]
    close $handle
    if {[string first "There are 0 invalid constraints." $health] < 0 ||
        [string first "There are 0 constraints that have no timing paths." $health] < 0} {
        error "Invalid or empty timing constraints; reports retained"
    }
    commit_param -step bitgen
    file mkdir $release
    bitgen -bit $release/$bit_name
    if {![file exists $release/$bit_name] || [file size $release/$bit_name] == 0} {
        error "Missing or empty bitstream output"
    }
    file mkdir $report_release
    foreach name {handfixed_candidate_pr.timing handfixed_candidate_phy.area handfixed_candidate_constraints.timing} {
        file copy -force $physical/$name $report_release/$name
    }
    puts "FIXED_BACKGROUND_BITGEN_PASS: $release/$bit_name"
} detail]} {
    puts stderr "HANDFIXED_BACKGROUND_BUILD_FAIL: $detail"
    exit 1
}
exit 0

