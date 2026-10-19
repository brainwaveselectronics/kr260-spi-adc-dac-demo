################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# @brief   JTAG development loop: program the K26 with the .bit, attach the
#          .ltx, refresh the device and list the ILA cores and their probes.
# @details Run from vivado/scripts with the KR260 connected over USB-JTAG
#          (micro-USB J4, FTDI; hw_server is started by Vivado if needed):
#              vivado -mode batch -nojournal -log ../build/program.log -source program.tcl \
#                     [-tclargs -bit ../output/kr260_spi_demo.bit -ltx ../output/kr260_spi_demo.ltx \
#                               -hw_server localhost:3121 -jtag_target <glob> -hw_device xck26* \
#                               -no_program -dryrun]
#          * Programming the PL over JTAG works while Linux runs on the PS;
#            Linux' fpga-manager does not notice. A later "xmutil loadapp"
#            overwrites the JTAG-loaded design (kr260-deployment report 5).
#          * Because the design clocks itself from the carrier's 25 MHz
#            oscillator, the ILAs are alive right after programming - no
#            pl_clk0 enable is needed.
#          * -no_program: only connect, attach the .ltx and refresh (ILAs on a
#            board that already runs the design, e.g. after the Linux autoload).
#          * -dryrun: print the flow without touching hardware (syntax check).
#          Exit codes: 0 ok, 20 no JTAG target, 21 no K26 device, 22 files missing.
################################################################################
set demo_sourced_by "program.tcl"
source [file join [file dirname [info script]] settings.tcl]
demo_parse_args $::argv
demo_resolve_paths
demo_dump_settings

# Same dry-run wrapper idea as build.tcl, with hardware-flavoured canned results.
proc dry_result {args} {
    switch -exact -- [lindex $args 0] {
        get_hw_targets    { return "localhost:3121/xilinx_tcf/Xilinx/dryrun" }
        get_hw_devices    { return "xck26_0" }
        current_hw_device { return "xck26_0" }
        get_hw_ilas       { return "hw_ila_1 hw_ila_2" }
        get_hw_probes     { return "dbg_probe" }
        get_property      { return "dryrun" }
        default           { return "" }
    }
}
proc vcmd {args} {
    if {$::dryrun} {
        puts "\[dryrun\] $args"
        return [dry_result {*}$args]
    }
    return [uplevel 1 $args]
}

if {!$dryrun && ![demo_in_vivado]} {
    demo_die "program.tcl needs Vivado (or -dryrun): vivado -mode batch -source program.tcl -tclargs ..." 2
}

# ------------------------------------------------------------------------------
# 1. Files
# ------------------------------------------------------------------------------
if {!$dryrun} {
    if {$program_dev && ![file exists $bit_file]} { demo_die "bitstream not found: $bit_file (run build.tcl first or pass -bit)" 22 }
    if {![file exists $ltx_file]} {
        demo_msg WARNING "probes file not found: $ltx_file - the device is programmed but the ILAs will not be visible"
        set ltx_file ""
    }
}

# ------------------------------------------------------------------------------
# 2. Connect: hw_server -> JTAG target -> K26 device
# ------------------------------------------------------------------------------
vcmd open_hw_manager
vcmd connect_hw_server -url $hw_server
set targets [vcmd get_hw_targets -quiet]
if {[llength $targets] == 0} {
    demo_die "no JTAG target on $hw_server - is the KR260 powered and the micro-USB (J4) cable connected?" 20
}
demo_msg INFO "JTAG targets: $targets"
if {$jtag_target ne ""} {
    set targets [vcmd get_hw_targets -quiet $jtag_target]
    if {[llength $targets] == 0} { demo_die "no JTAG target matches '$jtag_target'" 20 }
}
if {[llength $targets] > 1} {
    demo_msg WARNING "more than one JTAG target - using the first; select another with -jtag_target <glob>"
}
set target [lindex $targets 0]
vcmd current_hw_target $target
vcmd open_hw_target
set devices [vcmd get_hw_devices -quiet $hw_device]
if {[llength $devices] == 0} {
    demo_die "no device matching '$hw_device' on target $target (all devices: [vcmd get_hw_devices -quiet])" 21
}
set dev [lindex $devices 0]
vcmd current_hw_device $dev
demo_msg INFO "device: $dev"

# ------------------------------------------------------------------------------
# 3. Program and attach probes
# ------------------------------------------------------------------------------
vcmd refresh_hw_device -update_hw_probes false $dev
if {$program_dev} {
    vcmd set_property PROGRAM.FILE $bit_file $dev
    demo_msg INFO "programming $bit_file ..."
    vcmd program_hw_devices $dev
    demo_msg INFO "programmed (DONE)"
} else {
    demo_msg INFO "-no_program: leaving the running design in place"
}
if {$ltx_file ne ""} {
    vcmd set_property PROBES.FILE      $ltx_file $dev
    vcmd set_property FULL_PROBES.FILE $ltx_file $dev
}
vcmd refresh_hw_device $dev

# ------------------------------------------------------------------------------
# 4. Report the debug cores (expect 2 ILAs: ila_spi with 7 pin probes, ila_wave with 4)
# ------------------------------------------------------------------------------
set ilas [vcmd get_hw_ilas -quiet -of_objects $dev]
if {[llength $ilas] == 0} {
    demo_msg WARNING "no ILA cores detected - check: .ltx attached? MMCM locked (heartbeat LED)? design programmed?"
} else {
    foreach ila $ilas {
        demo_msg INFO "ILA [vcmd get_property NAME $ila] cell=[vcmd get_property CELL_NAME $ila]"
        foreach p [vcmd get_hw_probes -quiet -of_objects $ila] {
            set w ""
            catch { set w [vcmd get_property WIDTH $p] }           ;# 2025.2 name
            if {$w eq ""} { catch { set w [vcmd get_property PROBE_WIDTH $p] } }
            set cn ""
            catch { set cn [vcmd get_property NAME.CUSTOM $p] }    ;# block-design net name
            demo_msg INFO "    probe [vcmd get_property NAME $p] ($cn) width=$w"
        }
    }
}
if {[llength $ilas] != 2} {
    demo_msg WARNING "expected 2 ILA cores, found [llength $ilas]"
}
demo_msg INFO "next: open the Hardware Manager GUI, source hw_demo.tcl, run demo_setup then demo_arm"
exit 0
