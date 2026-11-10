# Programs the Arty S7 board of ALVIE/Sancus-FPGA with an image, after checking that it is a known image.
#
#   vivado -mode batch -nojournal -nolog -source program_fpga.tcl -tclargs COMMIT|BITSTREAM
#
# COMMIT (e.g. bf89c0b) programs the image of that Sancus commit in alvie/fpga/images. BITSTREAM is a file, .bit or
# .bit.gz. The SHA-256 of the bitstream (uncompressed) must be one of the images below, which says the Sancus commit
# to give to alvie sancus-fpga as --commit (see docs/sancus/fpga.md). The board keeps the image until it loses power.

# The images of alvie/fpga/images, built from the board project (scripts/build.tcl) and accepted by tt_stress_fpga.
# They say which commit they run, and ALVIE checks it against --commit.
set images {
    a042472d3ee9f42c8bac72d8e9af7803a07fbbe83751083e422647cbb9e794db {inst_number_50_ef753b6 ef753b6}
    d404b163748bccf52ab082a8808807147e76cd1dfaab1117106b8c75dc21bac5 {inst_number_50_e8cf011 e8cf011}
    c72770d7e1bb0b08f128bc190408b2a79e56fb964603a2e1d0fd89aa4019ee65 {inst_number_50_3170d5d 3170d5d}
    eb3992a94d101de44f0b5d71265a2a48a42b693dab9af626ccd0e929b6669358 {inst_number_50_6475709 6475709}
    1da80c4df0f8b79756a6ef6f846ecd8d802df68d727917bfcfa9f6ada881d5aa {inst_number_50_3636536 3636536}
    669241632c2418627ef5e95c54aea41e7a7cdbaa421e3c01e4035447f7373860 {inst_number_50_d54f031 d54f031}
    7df7abc941dddf7a97723e814f220463dd4c573f62767e74af6aec922e44f5d0 {inst_number_50_bf89c0b bf89c0b}
}
# Commits whose image is that of another commit with the same core (git diff of core/rtl/verilog is empty)
set sameCore {264f135 bf89c0b}
# Earlier images, not in alvie/fpga/images, which do not say which commit they run
set earlier {
    8270dd57894434a9a05e58c2ee84791f47ec830f4904f3d2cc6b3b7fe5272eb3 {inst_number_50_ef753b6 ef753b6}
    c9f88a18a68b7a84c51062753f7b5f9cf83a62f65a39cd8dba3951788f567b9b {inst_number_50 bf89c0b}
}
set imageDir [file normalize [file join [file dirname [info script]] .. fpga images]]

if {[llength $argv] != 1} {
    error "Usage: vivado -mode batch -source program_fpga.tcl -tclargs COMMIT|BITSTREAM"
}
set arg [lindex $argv 0]
if {[file exists $arg]} {
    set source $arg
} elseif {[regexp {^[0-9a-fA-F]{7,40}$} $arg]} {
    set c [string tolower [string range $arg 0 6]]
    if {[dict exists $sameCore $c]} {
        puts "--- $c has the same core as [dict get $sameCore $c]: its image runs both ---"
        set c [dict get $sameCore $c]
    }
    set source [file join $imageDir "inst_number_50_${c}.bit.gz"]
    if {![file exists $source]} {
        error "There is no image of Sancus commit $c in $imageDir: see docs/sancus/fpga.md to build one"
    }
} else {
    error "$arg is neither a bitstream nor a Sancus commit"
}

# The bitstream, uncompressed
if {[string match *.gz $source]} {
    set chan [file tempfile bitFile alvie-image.bit]
    close $chan
    exec gzip -dc $source > $bitFile
} else {
    set bitFile $source
}
set sha [lindex [exec sha256sum $bitFile] 0]
if {[dict exists $images $sha]} {
    lassign [dict get $images $sha] image commit
} elseif {[dict exists $earlier $sha]} {
    lassign [dict get $earlier $sha] image commit
    puts "--- $source is an earlier image of $commit, which does not say which commit it runs: alvie/fpga/images has one that does ---"
} else {
    error "$source (SHA-256 $sha) is not a known image of ALVIE/Sancus-FPGA: see docs/sancus/fpga.md"
}
puts "--- $source: image $image, Sancus commit $commit ---"

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
if {$bitFile ne $source} {
    file delete $bitFile
}

puts "--- Programmed with image $image: run alvie sancus-fpga with --commit $commit ---"
