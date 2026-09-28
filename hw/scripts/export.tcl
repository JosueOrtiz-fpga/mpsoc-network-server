# Export the fixed hardware platform (XSA) including the bitstream.
#
# The XSA is the single handoff to the software side. Its path comes
# from XSA_FILE, set by hw/Makefile to a name carrying the git hash and
# Vivado version.

source [file join [file dirname [info script]] common.tcl]

set xsa_file [env_or XSA_FILE [file join $out_dir ${proj_name}.xsa]]

open_project $proj_file
open_run impl_1

file mkdir [file dirname $xsa_file]
write_hw_platform -fixed -include_bit -force -file $xsa_file
puts "INFO: XSA written to $xsa_file"

# The same bitstream the XSA embeds, named after the XSA: that is the name the
# PL overlay's firmware-name uses. hw-plpkg builds the .bit.bin from this copy.
set top     [env_or TOP [get_property top [current_fileset]]]
set run_bit [file join [get_property DIRECTORY [get_runs impl_1]] ${top}.bit]
if {![file exists $run_bit]} { error "bitstream not found: $run_bit" }
set xsa_bit "[file rootname $xsa_file].bit"
file copy -force $run_bit $xsa_bit
puts "INFO: bitstream copied to $xsa_bit"

close_project
