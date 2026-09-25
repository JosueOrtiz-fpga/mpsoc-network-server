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

close_project
