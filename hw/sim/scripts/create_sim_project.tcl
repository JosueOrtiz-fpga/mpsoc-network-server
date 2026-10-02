# Build the simulation block design and export it for xsim.
#
# Creates a disposable project in build/sim/vivado, sources
# hw/bd/sim_mpsco_bd.tcl into it, generates the simulation targets and
# runs export_simulation into build/sim/export. hw/sim/Makefile compiles
# the exported sources together with hw/rtl/top.sv (SIM=1) and the
# testbench. The synthesis project (hw/scripts/create_project.tcl) never
# sees this block design.

source [file normalize [file join [file dirname [info script]] .. .. scripts common.tcl]]

set sim_build   [file normalize [env_or SIM_BUILD_DIR [file join $hw_dir .. build sim]]]
set sim_bd_name [env_or SIM_BD_NAME sim_mpsco_bd]
set sim_proj    [file join $sim_build vivado]
set export_dir  [file join $sim_build export]

file delete -force $sim_proj $export_dir
create_project ${proj_name}_sim $sim_proj -part $part

if {[llength [get_board_parts -quiet $board_part]] == 0} {
    error "Board part '$board_part' not found; see hw/scripts/create_project.tcl."
}
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]

# The generated script builds the design in the open project and ends with
# validate_bd_design + save_bd_design.
source [file join $hw_dir bd ${sim_bd_name}.tcl]

set bd_file [get_files -quiet ${sim_bd_name}.bd]
if {$bd_file eq ""} {
    error "Block design '$sim_bd_name' was not created; check the messages above."
}
generate_target simulation $bd_file

export_ip_user_files -of_objects $bd_file -no_script -force -quiet
export_simulation -of_objects $bd_file -simulator xsim -directory $export_dir -force

# Record the libraries the exported elaboration step links against, so
# the Makefile can elaborate the testbench with the same set.
set xsim_dir [file join $export_dir $sim_bd_name xsim]
set script [glob -nocomplain [file join $xsim_dir ${sim_bd_name}.sh]]
if {$script eq ""} {
    error "export_simulation did not write ${sim_bd_name}.sh under $xsim_dir"
}
set fh [open $script r]
set text [read $fh]
close $fh
set libs {}
foreach {- lib} [regexp -all -inline -- {-L\s+(\S+)} $text] {
    if {[lsearch -exact $libs $lib] < 0} { lappend libs $lib }
}
set fh [open [file join $xsim_dir elab_libs.txt] w]
puts $fh [join $libs "\n"]
close $fh
puts "INFO: exported $sim_bd_name for xsim to $xsim_dir ([llength $libs] libraries)"
close_project
