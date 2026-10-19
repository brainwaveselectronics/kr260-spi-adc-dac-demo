################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @brief   Fallback software build with the classic XSCT commands (deprecated in
#          Vitis 2024+, still shipped in 2025.2):   xsct build_sw_xsct.tcl [xsa]
# @details platform create (standalone, microblaze_0) -> app create (empty C)
#          -> import spi_demo.c -> app build -> sw/output/spi_demo.elf
################################################################################
set here [file dirname [file normalize [info script]]]
set xsa  [expr {[llength $argv] > 0 ? [lindex $argv 0] : [file join $here .. vivado output kr260_spi_demo.xsa]}]
set ws   [file join $here build xsct_ws]
set out  [file join $here output]
file mkdir $out
if {![file exists $xsa]} { puts "ERROR: XSA not found: $xsa"; exit 1 }
setws $ws
if {[catch {
    platform create -name kr260_mb_platform -hw $xsa -proc microblaze_0 -os standalone -out $ws
    platform write
    platform generate
    app create -name spi_demo -platform kr260_mb_platform -domain standalone_domain -template {Empty Application(C)}
    importsources -name spi_demo -path [file join $here spi_demo.c] -target-path src
    app build -name spi_demo
} err]} { puts "ERROR: $err"; exit 1 }
set elf [file join $ws spi_demo Debug spi_demo.elf]
if {![file exists $elf]} { set elf [lindex [glob -nocomplain [file join $ws spi_demo * spi_demo.elf]] 0] }
if {$elf eq "" || ![file exists $elf]} { puts "ERROR: no ELF produced"; exit 1 }
file copy -force $elf [file join $out spi_demo.elf]
puts "DONE: [file join $out spi_demo.elf]"
exit 0
