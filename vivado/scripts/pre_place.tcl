################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @brief   STEPS.PLACE_DESIGN.TCL.PRE hook: keep every register of the two AXI
#          Quad SPI cores out of the HD I/O blocks (IOB = FALSE) so that the
#          System ILA may probe the pad nets (DRC PDRC-248 otherwise). Also
#          clears IOB on the SPI/LED ports themselves. Runs inside impl_1 right
#          before place_design; prints what it changed.
################################################################################
set regs [get_cells -quiet -hierarchical -filter {NAME =~ "*axi_quad_spi_*" && PRIMITIVE_TYPE =~ REGISTER.*}]
if {[llength $regs] > 0} {
    set_property IOB FALSE $regs
    puts "pre_place.tcl: IOB FALSE on [llength $regs] registers of the AXI Quad SPI cores"
} else {
    puts "pre_place.tcl: WARNING no AXI Quad SPI registers found"
}
set iob_ports [get_ports -quiet {adc_cs_n_o[0] adc_sclk_o adc_d0_i adc_d1_i dac_sync_n_o[0] dac_sclk_o dac_dina_o dac_dinb_o}]
if {[llength $iob_ports] > 0} {
    set_property IOB FALSE $iob_ports
    puts "pre_place.tcl: IOB FALSE on [llength $iob_ports] SPI ports"
}
set still [get_cells -quiet -hierarchical -filter {IOB == TRUE && NAME =~ "*axi_quad_spi_*"}]
puts "pre_place.tcl: SPI-core cells still IOB=TRUE: [llength $still] $still"
