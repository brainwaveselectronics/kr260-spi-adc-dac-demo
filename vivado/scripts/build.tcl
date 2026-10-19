################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# @brief   Synthesis -> implementation -> bitstream -> debug probes -> reports.
# @details Run from vivado/scripts (after create_project.tcl):
#              vivado -mode batch -nojournal -log ../build/build.log -source build.tcl \
#                     [-tclargs -build_folder build -project_name kr260_spi_demo -threads 8 -output_dir ../output]
#          Steps: reset synth_1, launch synth_1 (-jobs N, the IP OOC runs are
#          launched automatically), wait, launch impl_1 to write_bitstream, wait,
#          open the implemented design, check that all timing constraints are met
#          (exit 55 if not, like the author's implement.tcl), write
#          <build_folder>/<project_name>.ltx, copy .bit/.ltx to vivado/output/
#          as <project_name>.bit/.ltx and write timing / utilization / DRC /
#          methodology / IO reports to vivado/output/. Exit non-zero on failure.
#          -dryrun: executes the complete flow logic with every Vivado command
#          replaced by a print (works inside vivado AND in plain tclsh:
#          "tclsh build.tcl -dryrun"), so the whole file is parsed and executed.
################################################################################
set demo_sourced_by "build.tcl"
source [file join [file dirname [info script]] settings.tcl]
demo_parse_args $::argv
demo_resolve_paths
demo_dump_settings
if {!$dryrun} { demo_check_vivado_version }

# ------------------------------------------------------------------------------
# vcmd: every Vivado interaction goes through here. In -dryrun mode the command
# is printed and a plausible result is returned so that the flow logic runs
# through; otherwise the command is executed in the caller's scope.
# ------------------------------------------------------------------------------
proc dry_result {args} {
    set cmd [lindex $args 0]
    switch -exact -- $cmd {
        get_property {
            # run objects are passed through as their names in dry-run mode
            set obj [lindex $args 2]
            switch -exact -- [lindex $args 1] {
                STATUS      { if {[string match "synth*" $obj]} { return "synth_design Complete!" } else { return "write_bitstream Complete!" } }
                PROGRESS    { return "100%" }
                NAME        { return "dryrun_object" }
                default     { return "" }
            }
        }
        report_timing_summary { return "All user specified timing constraints are met." }
        report_drc            { return "" }
        get_runs              { return [lrange $args 1 end] }
        get_debug_cores       { return "dbg_hub" }
        get_nets              { return [lrange $args 1 end] }
        get_pins              { return [lrange $args 1 end] }
        write_debug_probes    { return [lindex $args end] }
        write_hw_platform     { return [lindex $args end] }
        write_mem_info        { return [lindex $args end] }
        get_cells             { return "" }
        default               { return "" }
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
    demo_die "build.tcl needs Vivado (or -dryrun): vivado -mode batch -source build.tcl -tclargs ..." 2
}
if {!$dryrun && ![file exists $xpr_file]} {
    demo_die "project not found: $xpr_file - run create_project.tcl first" 3
}

# Returns 1 when a run finished its last step without error.
proc run_ok {run expected_step} {
    set status   [vcmd get_property STATUS   [vcmd get_runs $run]]
    set progress [vcmd get_property PROGRESS [vcmd get_runs $run]]
    demo_msg INFO "$run: STATUS='$status' PROGRESS='$progress'"
    if {[string match "*ERROR*" $status] || [string match -nocase "*fail*" $status]} { return 0 }
    if {![string match "*$expected_step Complete!*" $status]} { return 0 }
    return 1
}

set t_start [clock seconds]
file mkdir $output_dir

# ------------------------------------------------------------------------------
# 1. Open project, synthesis (IP OOC runs are launched implicitly)
# ------------------------------------------------------------------------------
vcmd open_project $xpr_file
vcmd update_compile_order -fileset sources_1
vcmd reset_run synth_1
vcmd launch_runs synth_1 -jobs $nr_jobs
vcmd wait_on_runs synth_1
if {![run_ok synth_1 synth_design]} {
    demo_die "synthesis failed - see $project_folder/$project_name.runs/synth_1/runme.log" 10
}

# ------------------------------------------------------------------------------
# 2. Implementation incl. bitstream
# ------------------------------------------------------------------------------
vcmd launch_runs impl_1 -to_step write_bitstream -jobs $nr_jobs
vcmd wait_on_runs impl_1
if {![run_ok impl_1 write_bitstream]} {
    demo_die "implementation / write_bitstream failed - see $project_folder/$project_name.runs/impl_1/runme.log" 11
}

# ------------------------------------------------------------------------------
# 3. Implemented design: timing gate, reports, debug probes
# ------------------------------------------------------------------------------
vcmd open_run impl_1
set rpt_prefix [file join $output_dir $project_name]

set timing_rpt [vcmd report_timing_summary -no_header -no_detailed_paths -return_string]
vcmd report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -max_paths 10 -input_pins -routable_nets -file ${rpt_prefix}_timing_summary.rpt
if {![string match -nocase "*timing constraints are met*" $timing_rpt]} {
    demo_die "TIMING NOT MET - see ${rpt_prefix}_timing_summary.rpt" 55
}
demo_msg INFO "timing: all user specified timing constraints are met"

vcmd report_utilization -file ${rpt_prefix}_utilization.rpt
vcmd report_utilization -hierarchical -file ${rpt_prefix}_utilization_hier.rpt
vcmd report_drc -file ${rpt_prefix}_drc.rpt
vcmd report_methodology -file ${rpt_prefix}_methodology.rpt
vcmd report_io -file ${rpt_prefix}_io.rpt
vcmd report_clock_utilization -file ${rpt_prefix}_clock_utilization.rpt
vcmd report_clocks -file ${rpt_prefix}_clocks.rpt

# Debug hub check: it is inserted by implementation and must sit on the 100 MHz clock.
set hub [vcmd get_debug_cores -quiet dbg_hub]
if {$hub ne ""} {
    set hub_clk [vcmd get_nets -quiet -of_objects [vcmd get_pins -quiet dbg_hub/clk]]
    demo_msg INFO "debug hub present, clock net: '$hub_clk'"
} else {
    demo_msg WARNING "no dbg_hub found in the implemented design - ILAs will not be visible in the Hardware Manager"
}
# System ILAs inside the block design are hierarchical cells; count them by name.
set ila_cells [vcmd get_cells -quiet -hierarchical -filter {NAME =~ "*/ila_spi" || NAME =~ "*/ila_wave"}]
demo_msg INFO "ILA cells: [llength $ila_cells] ($ila_cells)"

# Hardware handoff for the Vitis software build (sw/build_sw.py) and the BRAM
# memory map for merging the MicroBlaze ELF into the bitstream (sw/merge_elf.sh).
set xsa_file [file join $output_dir $xsa_name]
vcmd write_hw_platform -fixed -include_bit -force $xsa_file
demo_msg INFO "hardware platform (XSA): $xsa_file"
set mmi_file [file join $output_dir "$project_name.mmi"]
vcmd write_mem_info -force $mmi_file
demo_msg INFO "memory map info (MMI): $mmi_file"

# Debug probes file next to the project (spec: build/<project>.ltx) and a copy in output/.
vcmd write_debug_probes -force $ltx_build_file
demo_msg INFO "debug probes: $ltx_build_file"

# Read the .ltx (JSON in 2023.1) back: one line per ILA core with its probe -> net names.
# This is what the Hardware Manager will show; hw_demo.tcl addresses probes by these names.
if {!$dryrun && [file exists $ltx_build_file]} {
    set fh [open $ltx_build_file r]
    set ltx [read $fh]
    close $fh
    set n_ila 0
    set core ""
    foreach line [split $ltx "\n"] {
        if {[regexp {"spec":\s*"labtools_ila_v6"} $line]} { incr n_ila }
        if {[regexp {"name":\s*"([A-Za-z0-9_/.]*ila[A-Za-z0-9_/.]*)"} $line -> c] && [string first "/" $c] >= 0} { set core $c; demo_msg INFO "ltx core: $core" }
        if {[regexp {^\s{40}"name":\s*"([^"]+)"} $line -> net]} { demo_msg INFO "    probe net: $net" }
    }
    if {$n_ila != 2} {
        demo_msg WARNING "expected 2 ILA cores in the .ltx, found $n_ila"
    } else {
        demo_msg INFO "ltx: 2 ILA cores found"
    }
}

# ------------------------------------------------------------------------------
# 4. Deliverables: <output_dir>/<project_name>.bit and .ltx
# ------------------------------------------------------------------------------
set bit_src [file join $project_folder "$project_name.runs" impl_1 "$top_name.bit"]
if {$dryrun} {
    puts "\[dryrun\] file copy $bit_src -> [file join $output_dir $project_name.bit]"
    puts "\[dryrun\] file copy $ltx_build_file -> [file join $output_dir $project_name.ltx]"
} else {
    if {![file exists $bit_src]} { demo_die "bitstream not found: $bit_src" 12 }
    file copy -force $bit_src       [file join $output_dir "$project_name.bit"]
    file copy -force $ltx_build_file [file join $output_dir "$project_name.ltx"]
    demo_msg INFO "bitstream: [file join $output_dir $project_name.bit] ([file size $bit_src] bytes)"
    demo_msg INFO "probes:    [file join $output_dir $project_name.ltx]"
    # Short DRC digest for the console
    if {[file exists ${rpt_prefix}_drc.rpt]} {
        set fh [open ${rpt_prefix}_drc.rpt r]
        set drc [read $fh]
        close $fh
        foreach line [split $drc "\n"] {
            if {[regexp {^(Violations found|Rule Deck|Rules Found|No violations)} $line] || [regexp {^\| (Error|Critical|Warning|Advisory)} $line]} { demo_msg INFO "DRC: $line" }
        }
    }
}

vcmd close_project
demo_msg INFO "build finished in [expr {[clock seconds] - $t_start}] s"
exit 0
