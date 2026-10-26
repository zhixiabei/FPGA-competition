# RGB128 build. Enforce routed Slice <= 90% before producing a bitstream.
set flow_path [file join [file dirname [info script]] build_handfixed_background.tcl]
set h [open $flow_path r]
set flow [read $h]
close $h
set needle {    commit_param -step bitgen}
if {[llength [split $flow $needle]] == 0 || [string first $needle $flow] < 0} {
    error "Base build flow changed; resource guard cannot be inserted"
}
set guard {
    set h [open $physical/handfixed_candidate_phy.area r]
    set area [read $h]
    close $h
    foreach {name limit} {slice 19094 eram 108 dsp 40} {
        set pattern [format {#%s\s+(\d+)\s+out of\s+(\d+)} $name]
        if {![regexp $pattern $area unused used capacity] || $used > $limit} {
            error "RGB128 final $name resource limit failed; no bitstream released"
        }
        puts "FRUIT128_RESOURCE_PASS $name=$used/$capacity limit=$limit"
    }
    commit_param -step bitgen
}
set flow [string map [list $needle $guard] $flow]
set env(FRUITFIXED_BUILD) 1
if {![info exists env(HANDFIXED_BUILD_PROJECT)] || $env(HANDFIXED_BUILD_PROJECT) eq ""} {
    set env(HANDFIXED_BUILD_PROJECT) [file normalize [file join [file dirname [info script]] .. build fruit td]]
}
eval $flow
