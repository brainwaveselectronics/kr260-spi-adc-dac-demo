################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# @brief   Creates the Vivado 2025.2 project kr260_spi_demo: PS-less block
#          design spi_demo_bd (MicroBlaze + 2x AXI Quad SPI + GPIO + 2 System ILA,
#          clocked from the carrier's 25 MHz oscillator), heartbeat.vhd as the
#          only RTL, two XDCs, wrapper as top.
# @details Run from vivado/scripts:
#              vivado -mode batch -nojournal -log ../build/create_project.log \
#                     -source create_project.tcl [-tclargs -build_folder build -project_name kr260_spi_demo \
#                                                  -rtl_dir ../../hdl/rtl -threads 8 -noforce]
#          * Project: <build_folder>/<project_name>/<project_name>.xpr, part
#            xck26-sfvc784-2LV-c, board part xilinx.com:kr260_som:part0:1.1 with
#            the kr260_carrier connections (board files from the Vivado install;
#            the copy in vivado/board_files is added to board.repoPaths only if
#            the board part is not found).
#          * All hdl/rtl/*.vhd files as VHDL 2008 (heartbeat.vhd, used as a
#            module reference inside the block design).
#          * Block design built by create_bd.tcl (sourced here), validated,
#            wrapper generated and set as top; the BD picture is exported to
#            docs/block_design.{pdf,svg} for the README.
#          * synth_design -assert is enabled so the VHDL generic asserts of the
#            RTL are evaluated during synthesis.
#          Exit code 0 on success, non-zero on any failure (batch friendly).
################################################################################
set demo_sourced_by "create_project.tcl"
source [file join [file dirname [info script]] settings.tcl]
demo_parse_args $::argv
demo_resolve_paths
demo_dump_settings
demo_check_vivado_version

if {![demo_in_vivado]} {
    demo_die "create_project.tcl needs Vivado: vivado -mode batch -source create_project.tcl -tclargs ..." 2
}

# ------------------------------------------------------------------------------
# 1. Input checks
# ------------------------------------------------------------------------------
set rtl_files [lsort [glob -nocomplain -directory $rtl_dir *.vhd *.vhdl]]
if {[llength $rtl_files] == 0} {
    demo_die "no VHDL files found in $rtl_dir" 3
}
set have_heartbeat 0
foreach f $rtl_files {
    demo_msg INFO "RTL: $f"
    if {[string match "heartbeat.vhd*" [file tail $f]]} { set have_heartbeat 1 }
}
if {!$have_heartbeat} {
    demo_die "heartbeat.vhd not found in $rtl_dir (the block design references it)" 3
}
foreach f $constraint_files {
    if {![file exists $f]} { demo_die "constraint file missing: $f" 3 }
}
if {[file exists $xpr_file] && !$force} {
    demo_die "project exists: $xpr_file (use -force to overwrite)" 4
}

# ------------------------------------------------------------------------------
# 2. Board part: Vivado install first, fallback copy in vivado/board_files
# ------------------------------------------------------------------------------
set bp [get_board_parts -quiet $board_part]
if {$bp eq ""} {
    demo_msg WARNING "board part $board_part not found in the Vivado install - adding fallback repo $board_repo_fallback"
    set repo_paths [get_param board.repoPaths]
    if {[lsearch -exact $repo_paths $board_repo_fallback] < 0} {
        set_param board.repoPaths [concat [list $board_repo_fallback] $repo_paths]
    }
    set bp [get_board_parts -quiet $board_part]
}
if {$bp eq ""} {
    demo_msg WARNING "board part $board_part still not found - continuing with the bare part $part (pins come from the XDC anyway)"
} else {
    demo_msg INFO "board part found: $bp"
}

# ------------------------------------------------------------------------------
# 3. Project
# ------------------------------------------------------------------------------
file mkdir $build_root
if {$force} {
    create_project $project_name $project_folder -part $part -force
} else {
    create_project $project_name $project_folder -part $part
}
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]
if {$bp ne ""} {
    set_property board_part $board_part [current_project]
    set_property board_connections $board_connections [current_project]
    demo_msg INFO "board_connections: [get_property board_connections [current_project]]"
}

# ------------------------------------------------------------------------------
# 4. Sources (VHDL-2008) and constraints
# ------------------------------------------------------------------------------
add_files -norecurse -fileset sources_1 $rtl_files
set_property file_type {VHDL 2008} [get_files $rtl_files]
# A block-design module reference must not be a "VHDL 2008" file (Vivado filemgmt 56-195):
# heartbeat.vhd is VHDL-93 compatible, so mark it plain VHDL.
set_property file_type {VHDL} [get_files -of_objects [get_filesets sources_1] *heartbeat.vhd]
add_files -norecurse -fileset constrs_1 $constraint_files
# Pins first, timing second (both PROCESSING_ORDER NORMAL - the order in the fileset decides).
set_property used_in_synthesis true      [get_files $constraint_files]
set_property used_in_implementation true [get_files $constraint_files]
set_property used_in_synthesis false     [get_files $impl_only_constraints]
set_property PROCESSING_ORDER LATE       [get_files $impl_only_constraints]

# ------------------------------------------------------------------------------
# 5. Block design (create_bd.tcl): cells, connections, addresses, validation,
#    wrapper (set as top inside the script)
# ------------------------------------------------------------------------------
update_compile_order -fileset sources_1
source [file join $script_dir create_bd.tcl]

# Picture of the block design for the README (docs/block_design.*)
set docs_dir [file join $repo_dir docs]
if {[file isdirectory $docs_dir]} {
    foreach fmt {pdf svg} {
        set img [file join $docs_dir "block_design.$fmt"]
        if {[catch {write_bd_layout -force -format $fmt -orientation landscape $img} e]} {
            demo_msg WARNING "write_bd_layout ($fmt) failed: $e"
        } else {
            demo_msg INFO "block design picture: $img"
        }
    }
}
close_bd_design [get_bd_designs $bd_name]

# ------------------------------------------------------------------------------
# 6. Run options
# ------------------------------------------------------------------------------
update_compile_order -fileset sources_1
# Evaluate VHDL asserts (heartbeat generic checks) during synthesis.
set_property STEPS.SYNTH_DESIGN.ARGS.ASSERT true [get_runs synth_1]
# Belt and braces for the IOB packing of the SPI cores (see kr260_impl.xdc): a
# pre-place hook applies IOB = FALSE on the cells right before place_design.
set_property STEPS.PLACE_DESIGN.TCL.PRE [file normalize [file join $script_dir pre_place.tcl]] [get_runs impl_1]

demo_msg INFO "project created: $xpr_file"
demo_msg INFO "top: [get_property top [current_fileset]]  part: [get_property part [current_project]]"
close_project
exit 0
