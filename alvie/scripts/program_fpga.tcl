# Programs the Arty S7 board of ALVIE/Sancus-FPGA with a bitstream, after checking that it is a known image.
#
#   vivado -mode batch -nojournal -nolog -source program_fpga.tcl -tclargs BITSTREAM
#
# The SHA-256 of the bitstream must be one of the images below, which says the Sancus commit to give to
# alvie sancus-fpga as --commit (see docs/sancus/fpga.md). The board keeps the image until it loses power.

set images {
    8270dd57894434a9a05e58c2ee84791f47ec830f4904f3d2cc6b3b7fe5272eb3 {inst_number_50_ef753b6 ef753b6}
    c9f88a18a68b7a84c51062753f7b5f9cf83a62f65a39cd8dba3951788f567b9b {inst_number_50 bf89c0b}
}

if {[llength $argv] != 1} {
    error "Usage: vivado -mode batch -source program_fpga.tcl -tclargs BITSTREAM"
}
set bitFile [lindex $argv 0]
if {![file exists $bitFile]} {
    error "Bitstream not found: $bitFile"
}
set sha [lindex [exec sha256sum $bitFile] 0]
if {![dict exists $images $sha]} {
    error "$bitFile (SHA-256 $sha) is not a known image of ALVIE/Sancus-FPGA: see docs/sancus/fpga.md"
}
lassign [dict get $images $sha] image commit
puts "--- $bitFile: image $image, Sancus commit $commit ---"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set device [lindex [get_hw_devices xc7s*] 0]
if {$device eq ""} {
    error "No Spartan-7 device on the JTAG chain: check that the board is connected"
}
current_hw_device $device
refresh_hw_device -update_hw_probes false $device
set_property PROGRAM.FILE $bitFile $device
program_hw_devices $device
refresh_hw_device $device
close_hw_manager

puts "--- Programmed with image $image: run alvie sancus-fpga with --commit $commit ---"
