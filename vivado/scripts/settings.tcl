################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# @brief   Common settings, paths, IP configuration and the argument parser for
#          all Vivado scripts in this directory.
# @details Sourced by create_project.tcl, build.tcl, program.tcl and hw_demo.tcl.
#          Everything is derived from the location of this file ([info script]),
#          so no user home is hard-coded. Command-line overrides follow the
#          author's existing scripts:  -project_name <n>  -build_folder <dir>
#          -threads <n> (alias -jobs) plus a few script-specific flags, all
#          passed after -tclargs:
#              vivado -mode batch -source create_project.tcl -tclargs -build_folder build
#          Standalone use (prints the resolved settings):
#              vivado -mode batch -source settings.tcl -tclargs -dump
#              tclsh settings.tcl -dump
#          This file must stay free of Vivado-only commands at source time so
#          that plain tclsh can run the -dryrun checks of build.tcl.
################################################################################

# ------------------------------------------------------------------------------
# Paths (relative to this file)
# ------------------------------------------------------------------------------
set script_dir          [file normalize [file dirname [info script]]]
set vivado_dir          [file normalize [file join $script_dir ..]]
set repo_dir            [file normalize [file join $vivado_dir ..]]
set rtl_dir             [file join $repo_dir hdl rtl]
set constr_dir          [file join $vivado_dir constraints]
set output_dir          [file join $vivado_dir output]
set wcfg_dir            [file join $vivado_dir wcfg]
set board_repo_fallback [file join $vivado_dir board_files]

# ------------------------------------------------------------------------------
# Project settings
# ------------------------------------------------------------------------------
set project_name "kr260_spi_demo"
set build_folder "build"            ;# relative to $vivado_dir unless absolute
set bd_name      "spi_demo_bd"       ;# IP-integrator block design (create_bd.tcl)
set top_name     "spi_demo_bd_wrapper" ;# generated wrapper = synthesis top
set part         "xck26-sfvc784-2LV-c"
set board_part   "xilinx.com:kr260_som:part0:1.1"
# The SOM board part needs the carrier connections to know the Pmod/LED/clock pins
# (set_property board_connections ... ; verified in Vivado 2023.1 on 13 Oct 2026).
set board_connections [list \
    som240_1_connector xilinx.com:kr260_carrier:som240_1_connector:1.0 \
    som240_2_connector xilinx.com:kr260_carrier:som240_2_connector:1.0]
set xsa_name     "kr260_spi_demo.xsa" ;# hardware handoff for Vitis (write_hw_platform)
set expected_vivado "2025.2"
set constraint_files [list \
    [file join $constr_dir kr260_pins.xdc] \
    [file join $constr_dir kr260_timing.xdc] \
    [file join $constr_dir kr260_impl.xdc]]
set impl_only_constraints [list [file join $constr_dir kr260_impl.xdc]]   ;# cell constraints: not for synthesis

# ------------------------------------------------------------------------------
# Tool settings
# ------------------------------------------------------------------------------
set nr_jobs  8
set force    1          ;# create_project -force (overwrite an existing project)
set dryrun   0          ;# build.tcl / program.tcl: print the flow, touch nothing

# ------------------------------------------------------------------------------
# Hardware (program.tcl / hw_demo.tcl)
# ------------------------------------------------------------------------------
set hw_server   "localhost:3121"
set jtag_target ""      ;# "" = the only (or first) target; else a glob for get_hw_targets
set hw_device   "xck26*" ;# glob for get_hw_devices
set bit_file    ""      ;# "" = $output_dir/$project_name.bit
set ltx_file    ""      ;# "" = $output_dir/$project_name.ltx
set program_dev 1       ;# program.tcl: 0 (-no_program) = only connect + refresh (ILAs on a running board)
set autoconnect 0       ;# hw_demo.tcl: 1 (-autoconnect) = run demo_connect + demo_setup when sourced

# ------------------------------------------------------------------------------
# IP configuration lives in create_bd.tcl (block design spi_demo_bd): clk_wiz 6.0
# (25 -> 100 MHz), MicroBlaze 11.0 + 64 KB LMB + MDM(JTAG UART), 2x AXI Quad SPI 3.2
# (16-bit, manual SS, SCLK 100/16 MHz), AXI GPIO mirror/LED, 2x System ILA.
# Fixed addresses (sw/spi_demo.c): spi_adc 0x44A00000, spi_dac 0x44A10000,
# gpio_mirror 0x40000000, gpio_led 0x40010000.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
# Removes the first element of a list variable and returns it (as in the author's scripts).
proc lshift {listVar} {
    upvar 1 $listVar L
    set r [lindex $L 0]
    set L [lreplace $L [set L 0] 0]
    return $r
}

# Uniform console output; "level" is INFO, WARNING or ERROR.
proc demo_msg {level text} {
    puts "\[demo-flow $level\] $text"
}

# Abort with a message and a non-zero exit code (works in vivado batch and tclsh).
proc demo_die {text {code 1}} {
    demo_msg ERROR $text
    exit $code
}

# True when running inside Vivado (not plain tclsh).
proc demo_in_vivado {} {
    return [expr {[llength [info commands get_runs]] > 0 || [llength [info commands create_project]] > 0}]
}

# Warns when the running Vivado is not the version the flow was validated with
# (the stage laptop's Hardware Manager must match the version that built the ILAs).
proc demo_check_vivado_version {} {
    if {![demo_in_vivado]} { return }
    set v [version -short]
    if {![string match "$::expected_vivado*" $v]} {
        demo_msg WARNING "running Vivado $v, flow validated with $::expected_vivado - continue at your own risk"
    } else {
        demo_msg INFO "Vivado $v"
    }
}

# Parses the -tclargs. Unknown flags produce a warning and are skipped (also as
# in the author's scripts). Boolean flags take no value.
proc demo_parse_args {arglist} {
    set args $arglist
    while {[llength $args] > 0} {
        set flag [lshift args]
        switch -exact -- $flag {
            -project_name { set ::project_name [lshift args] }
            -build_folder { set ::build_folder [lshift args] }
            -rtl_dir      { set ::rtl_dir      [file normalize [lshift args]] }
            -output_dir   { set ::output_dir   [file normalize [lshift args]] }
            -wcfg_dir     { set ::wcfg_dir     [file normalize [lshift args]] }
            -threads -
            -jobs         { set ::nr_jobs      [lshift args] }
            -force        { set ::force 1 }
            -noforce      { set ::force 0 }
            -dryrun       { set ::dryrun 1 }
            -hw_server    { set ::hw_server    [lshift args] }
            -jtag_target  { set ::jtag_target  [lshift args] }
            -hw_device    { set ::hw_device    [lshift args] }
            -bit          { set ::bit_file     [file normalize [lshift args]] }
            -ltx          { set ::ltx_file     [file normalize [lshift args]] }
            -no_program   { set ::program_dev 0 }
            -autoconnect  { set ::autoconnect 1 }
            -dump         { set ::dump_settings 1 }
            -help -
            -h            {
                puts "Flags: -project_name <n> -build_folder <dir> -rtl_dir <dir> -output_dir <dir> -wcfg_dir <dir>"
                puts "       -threads|-jobs <n> -force|-noforce -dryrun -hw_server <host:port> -jtag_target <glob>"
                puts "       -hw_device <glob> -bit <file> -ltx <file> -no_program -autoconnect -dump -help"
                exit 0
            }
            default {
                demo_msg WARNING "unknown flag '$flag' ignored (use -help for the list)"
            }
        }
    }
}

# Resolves the derived paths after the arguments were parsed.
proc demo_resolve_paths {} {
    # -build_folder may be absolute or relative to vivado/ (never to the cwd)
    set ::build_root     [file normalize [file join $::vivado_dir $::build_folder]]
    set ::project_folder [file join $::build_root $::project_name]
    set ::xpr_file       [file join $::project_folder "$::project_name.xpr"]
    set ::ltx_build_file [file join $::build_root "$::project_name.ltx"]
    if {$::bit_file eq ""} {
        # the file to program is the bitstream with the MicroBlaze program merged in (sw/merge_elf.sh)
        set sw_bit [file join $::output_dir "${::project_name}_sw.bit"]
        if {[file exists $sw_bit]} { set ::bit_file $sw_bit } else { set ::bit_file [file join $::output_dir "$::project_name.bit"] }
    }
    if {$::ltx_file eq ""} { set ::ltx_file [file join $::output_dir "$::project_name.ltx"] }
}

proc demo_dump_settings {} {
    foreach v {repo_dir vivado_dir rtl_dir constr_dir output_dir wcfg_dir board_repo_fallback \
               project_name build_root project_folder xpr_file ltx_build_file bd_name top_name xsa_name part \
               board_part nr_jobs force dryrun hw_server jtag_target hw_device bit_file ltx_file} {
        demo_msg INFO [format "%-20s = %s" $v [set ::$v]]
    }
}

# ------------------------------------------------------------------------------
# Standalone use (settings.tcl -dump). The other scripts set ::demo_sourced_by
# before sourcing this file and do their own parsing.
# ------------------------------------------------------------------------------
set dump_settings 0
if {![info exists ::demo_sourced_by]} {
    if {[info exists ::argv]} { demo_parse_args $::argv }
    demo_resolve_paths
    if {$dump_settings} { demo_dump_settings }
}
