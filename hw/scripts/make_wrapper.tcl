# Regenerate the block design HDL wrapper into hw/rtl.
#
# Run after changing BD external ports (make hw-wrapper), then review
# and commit the diff. Custom edits to the committed wrapper would be
# overwritten, so put extra logic in a separate top-level module.

source [file join [file dirname [info script]] common.tcl]

open_project $proj_file

set bd_file [get_files ${bd_name}.bd]
make_wrapper -files $bd_file -top -force

set gen [glob -nocomplain [file join $proj_dir ${proj_name}.gen sources_1 bd $bd_name hdl ${top}.v]]
if {$gen eq ""} {
    error "Generated wrapper $top.v not found under the project .gen directory"
}
file copy -force $gen [file join $hw_dir rtl ${top}.v]
puts "INFO: updated [file join $hw_dir rtl ${top}.v]"

close_project
