################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @brief   xsim closed-loop smoke run: block design + MicroBlaze executing
#          sw/output/spi_demo.elf + behavioural AD7476A / DAC121S101 models.
# @details vivado -mode batch -source sim_closed_loop.tcl [-tclargs -run_us 650]
#          Needs the project (create_project.tcl) and the ELF (sw/build_sw.py).
#          Prints the testbench summary, samples the mirror GPIO word (the
#          software's view: ADC sample / DAC code / leading-zero nibble) a few
#          times via get_value, and exits 0 only on "TB RESULT: PASS".
################################################################################
set demo_sourced_by "sim_closed_loop.tcl"
source [file join [file dirname [info script]] settings.tcl]
set run_us 650      ;# the PASS thresholds need >= 20 ADC frames at ~31 us per DAC update (-O2)
set a $::argv
while {[llength $a] > 0} {
    set f [lindex $a 0]; set a [lrange $a 1 end]
    switch -exact -- $f {
        -run_us { set run_us [lindex $a 0]; set a [lrange $a 1 end] }
        default { lappend keep $f }
    }
}
if {[info exists keep]} { demo_parse_args $keep }
demo_resolve_paths
set elf [file join $repo_dir sw output spi_demo.elf]
set sim_dir [file join $repo_dir hdl sim]
set model_dir [file join $repo_dir hdl sim models]
foreach f [list $xpr_file $elf [file join $sim_dir tb_spi_demo_bd.vhd] [file join $model_dir ad7476a_model.vhd] [file join $model_dir dac121s101_model.vhd] [file join $model_dir tb_pkg.vhd]] {
    if {![file exists $f]} { demo_die "missing: $f" 3 }
}
open_project $xpr_file
# simulation sources (VHDL-2008): models + testbench; the ELF scoped to the MicroBlaze
set sim_files [list [file join $model_dir tb_pkg.vhd] [file join $model_dir ad7476a_model.vhd] \
                    [file join $model_dir dac121s101_model.vhd] [file join $sim_dir tb_spi_demo_bd.vhd]]
foreach f $sim_files { if {[get_files -quiet $f] eq ""} { add_files -fileset sim_1 -norecurse $f } }
set_property file_type {VHDL 2008} [get_files $sim_files]
if {[get_files -quiet $elf] eq ""} { add_files -fileset sim_1 -norecurse $elf }
set_property SCOPED_TO_REF $bd_name [get_files -all -of_objects [get_fileset sim_1] $elf]
set_property SCOPED_TO_CELLS { microblaze_0 } [get_files -all -of_objects [get_fileset sim_1] $elf]
set_property top tb_spi_demo_bd [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {0 us} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
generate_target simulation [get_files ${bd_name}.bd]
# The ELF -> block-RAM image for simulation: Vivado's launch_simulation did not
# produce <bd>_lmb_bram_0.mem from the associated ELF (2025.2, seen 13 Oct 2026),
# so the MEM files are generated explicitly (generate_mem_files merges the BMM
# of the design with the ELF) and copied next to the xsim scripts, where the
# blk_mem_gen simulation model reads C_INIT_FILE = "<bd>_lmb_bram_0.mem".
set xsim_dir [file join $project_folder "$project_name.sim" sim_1 behav xsim]
set mem_dir  [file join $build_root sim_mem]
file mkdir $xsim_dir
if {[catch {generate_mem_files -force $mem_dir} err]} { demo_msg WARNING "generate_mem_files failed: $err" }
set mems [glob -nocomplain [file join $mem_dir *.mem]]
demo_msg INFO "generate_mem_files wrote: $mems"
foreach m $mems { file copy -force $m $xsim_dir }
set bram_mem [glob -nocomplain [file join $xsim_dir *lmb_bram*.mem]]
if {[llength $bram_mem] == 0} {
    demo_msg WARNING "no *lmb_bram*.mem produced - the MicroBlaze will run an empty memory in simulation"
} else {
    demo_msg INFO "block RAM image for simulation: $bram_mem ([file size [lindex $bram_mem 0]] bytes)"
}
launch_simulation
set mirror_path "/tb_spi_demo_bd/dut/${bd_name}_i/axi_gpio_mirror/gpio_io_o"
set step 25
set t 0
set samples [list]
while {$t < $run_us} {
    run ${step} us
    set t [expr {$t + $step}]
    set v [get_value -radix hex $mirror_path]
    lappend samples "$t us: $v"
    demo_msg INFO "t = $t us  mirror = 0x$v"
}
# decode the last mirror words: [11:0] sample [23:12] code [24] toggle [28:25] zeros
set fails 0
foreach s $samples {
    regexp {(\d+) us: ([0-9a-fA-FxX]+)} $s -> tt hx
    if {[string match "*x*" [string tolower $hx]] || [string match "*u*" [string tolower $hx]]} { continue }
    set w [expr 0x$hx]
    set sample [expr {$w & 0xFFF}]
    set code   [expr {($w >> 12) & 0xFFF}]
    set zeros  [expr {($w >> 25) & 0xF}]
    set d [expr {abs($sample - $code)}]
    if {$w != 0 && ($zeros != 0 || $d > 4)} { incr fails; demo_msg WARNING "mirror at $tt us: sample $sample code $code zeros $zeros (diff $d)" }
}
close_sim
set log [file join $project_folder "$project_name.sim" sim_1 behav xsim simulate.log]
set pass 0
if {[file exists $log]} {
    set fh [open $log r]; set txt [read $fh]; close $fh
    foreach line [split $txt "\n"] { if {[string match "*tb_spi_demo_bd summary*" $line] || [string match "*TB RESULT*" $line] || [string match "*frames*" $line]} { demo_msg INFO [string trim $line] } }
    if {[string match "*TB RESULT: PASS*" $txt]} { set pass 1 }
}
if {$pass && $fails == 0} { demo_msg INFO "SIM RESULT: PASS (testbench PASS, mirror words consistent)"; exit 0 }
demo_die "SIM RESULT: FAIL (testbench pass=$pass, mirror inconsistencies=$fails) - see $log" 20
