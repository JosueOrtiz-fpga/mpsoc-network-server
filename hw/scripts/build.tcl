# Synthesis, implementation and bitstream, with a timing gate.
#
# Fails on run errors and on negative setup or hold slack, unless
# ALLOW_TIMING_FAIL=1. Reports are written to out/hw/reports.

source [file join [file dirname [info script]] common.tcl]

open_project $proj_file

# --- Synthesis ---------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
check_run synth_1

# --- Implementation through bitstream ---------------------------------
# write_bitstream DRCs (e.g. NSTD-1 / UCIO-1 for unconstrained I/O) are
# errors by default and will stop the run here.
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
check_run impl_1

# --- Reports -----------------------------------------------------------
open_run impl_1
set rpt_dir [file join $out_dir reports]
file mkdir $rpt_dir
report_timing_summary -max_paths 20 -file [file join $rpt_dir timing_summary.rpt]
report_utilization                  -file [file join $rpt_dir utilization.rpt]
report_drc                          -file [file join $rpt_dir drc.rpt]
report_methodology                  -file [file join $rpt_dir methodology.rpt]

# --- Timing gate -------------------------------------------------------
proc worst_slack {type} {
    set paths [get_timing_paths -delay_type $type -max_paths 1 -nworst 1]
    if {[llength $paths] == 0} {
        return ""
    }
    return [get_property SLACK [lindex $paths 0]]
}
set wns [worst_slack max]
set whs [worst_slack min]
puts "INFO: WNS = $wns ns, WHS = $whs ns"

set timing_ok 1
foreach {name slack} [list setup $wns hold $whs] {
    if {$slack eq ""} {
        puts "WARNING: no constrained $name paths found"
    } elseif {$slack < 0} {
        puts "ERROR: $name slack is negative ($slack ns)"
        set timing_ok 0
    }
}
if {!$timing_ok && !$allow_timing_fail} {
    error "Timing not met; see [file join $rpt_dir timing_summary.rpt]"
}

# --- Publish bitstream -------------------------------------------------
set bit [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] ${top}.bit]]
if {$bit eq ""} {
    error "Bitstream ${top}.bit not found in the impl_1 run directory"
}
file mkdir $out_dir
file copy -force $bit [file join $out_dir ${top}.bit]
puts "INFO: bitstream written to [file join $out_dir ${top}.bit]"

close_project
