################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @brief   Implementation-only constraints (used_in_synthesis = false).
# @details The AXI Quad SPI cores declare IOB = TRUE on their pin registers
#          (e.g. .../NO_DUAL_QUAD_MODE.QSPI_NORMAL/IO1_I_REG). A flop packed into
#          the HD I/O block may not share its pad net with anything else, but the
#          System ILA "ila_spi" probes exactly those pad nets (CS, SCLK, MISO,
#          MOSI) - Vivado 2025.2 stops placement with
#          DRC PDRC-248 "HDIOLOGIC_IPFF_unsupported_D_fanout". At 6.25 MHz SPI the
#          I/O-block packing buys nothing, so every register inside the two SPI
#          cores stays in the fabric and the probes can see the pins.
################################################################################
set spi_regs [get_cells -quiet -hierarchical -filter {NAME =~ "*axi_quad_spi_*" && PRIMITIVE_TYPE =~ REGISTER.SDR.*}]
if {[llength $spi_regs] > 0} {
    set_property IOB FALSE $spi_regs
}
