# Shared settings for all hardware build scripts.
#
# Values come from environment variables exported by hw/Makefile, with
# defaults so a script can also be sourced by hand from the Vivado Tcl
# console. Keep the defaults in sync with versions.env.

proc env_or {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default
}

set script_dir  [file normalize [file dirname [info script]]]
set hw_dir      [file normalize [env_or HW_DIR    [file join $script_dir ..]]]
set build_dir   [file normalize [env_or BUILD_DIR [file join $hw_dir .. build hw]]]
set out_dir     [file normalize [env_or OUT_DIR   [file join $hw_dir .. out hw]]]

set proj_name   [env_or PROJ_NAME zub1cg]
set proj_dir    [file join $build_dir vivado]
set proj_file   [file join $proj_dir ${proj_name}.xpr]
set bd_name     [env_or BD_NAME mpsoc_bd]
set top         [env_or TOP ${bd_name}_wrapper]

set part        [env_or PART xczu1cg-sbva484-1-e]
set board_part  [env_or BOARD_PART avnet-tria:zuboard_1cg:part0:1.2]
set board_repo  [env_or BOARD_REPO_PATH ""]
set jobs        [env_or JOBS 4]
set allow_timing_fail [env_or ALLOW_TIMING_FAIL 0]

# --- Tool version guard ----------------------------------------------
set expected_version [env_or VIVADO_VERSION ""]
if {$expected_version ne "" && [string first $expected_version [version -short]] != 0} {
    error "Vivado [version -short] found, but versions.env pins $expected_version."
}

# --- Optional extra board repository ----------------------------------
if {$board_repo ne ""} {
    set_param board.repoPaths [list [file normalize $board_repo]]
}

# Fail the build if a run did not complete.
proc check_run {run} {
    set progress [get_property PROGRESS [get_runs $run]]
    set status   [get_property STATUS   [get_runs $run]]
    if {$progress ne "100%" || [string match -nocase "*error*" $status]} {
        error "Run $run failed: $status (see its runme.log under the project runs directory)"
    }
    puts "INFO: $run finished: $status"
}
