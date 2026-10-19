################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# NOTE: adc_cs_n_o and dac_sync_n_o are 1-bit vectors ([0]) because the block-design
#       wrapper exposes the AXI Quad SPI ss_o[0:0] pins; all other SPI ports are scalars.
# @brief   Timing and bitstream constraints for kr260_top.
# @details One primary clock (25 MHz carrier oscillator). The 100 MHz system
#          clock is the MMCM output of clk_wiz_0 and is derived automatically
#          by Vivado (auto-generated clock "clk_out1_clk_wiz_0", 10.000 ns).
#          All SPI and LED pins are declared false paths; the manual timing
#          budget that justifies this is documented below (README.md
#          section 6: "SPI/LED ports as set_false_path with the manual timing
#          budget documented in a comment").
################################################################################

################################################################################
# 1. Primary clock: HPA_CLK0_P, 25 MHz on C3 (kr260_pins.xdc) -> period 40.000 ns.
#
#    The clock is DEFINED BY THE clk_wiz_0 IP, not here. With PRIM_SOURCE =
#    Single_ended_clock_capable_pin the IP contains the IBUF, its input pin IS the
#    top-level port, and its generated constraints (clk_wiz_0_in_context.xdc /
#    clk_wiz_0.xdc, processed before the user XDCs) issue
#        create_clock -period 40.000 [get_ports clk_in1]
#        set_input_jitter ... 0.400
#    on that port, from CONFIG.PRIM_IN_FREQ 25.000. Vivado names this clock after
#    the port: "clk_25m_i". A second create_clock on the same port is flagged by
#    Vivado 2025.2 (checked on 13 Oct 2026): a different name gives
#    "CRITICAL WARNING [Constraints 18-1056] Clock 'clk_25m' completely overrides
#    clock 'clk_25m_i'", the identical name still gives "WARNING [Constraints
#    18-619] ... overwriting the previous clock". To keep the build log clean the
#    primary clock is therefore owned by the IP (deviation from the first design note
#    section 6, which places the create_clock in this file; the constraint itself
#    is identical: 40.000 ns on clk_25m_i). The derived 100 MHz clock is
#    auto-derived from the MMCM as "clk_out1_clk_wiz_0" (10.000 ns).
#
#    Only if clk_wiz_0 is ever reconfigured to PRIM_SOURCE = No_buffer (IBUF in
#    kr260_top) does the IP stop defining the clock - then uncomment:
# create_clock -period 40.000 -name clk_25m_i -waveform {0.000 20.000} [get_ports clk_25m_i]
#
#    build.tcl writes report_clocks to output/<project>_clocks.rpt: expect
#    clk_25m_i 40.000 ns (propagated, user) and clk_out1_clk_wiz_0 10.000 ns (generated).
################################################################################

################################################################################
# 2. SPI pins and LEDs: false paths with a manual budget.
#
# Why false paths and not set_output_delay / set_input_delay:
#   Both converters are SPI slaves clocked by the SCLK the FPGA itself generates
#   from the same 100 MHz flip-flop clock edge as the data/select lines. Their
#   datasheet requirements are therefore RELATIVE between FPGA pins (SCLK vs DIN,
#   SCLK vs SYNC, SCLK vs MISO), not relative to an external sampling clock. A
#   system-synchronous set_output_delay/set_input_delay against clk_100m would
#   model a non-existent external clock and prove nothing; constraining the real
#   requirement (pin-to-pin skew of a few ns against 50 ns half periods) is not
#   what the timer is for. The budget is settled by construction and documented:
#
# Timing plan (README.md, 100 MHz fabric = 10 ns ticks,
# G_SCLK_HALF_TICKS = 5 -> SCLK 10 MHz, 100 ns period, 50 ns half period):
#
# ADC read, AD7476A (fSCLK max 20 MHz; SCLK idle high; data launched on SCLK
# falling edges F1..F15, first leading zero launched by CS falling):
#   * The master samples MISO at the fabric edge that PRODUCES the next SCLK
#     falling edge, i.e. one SCLK period (100 ns) after the launching edge.
#   * Setup side: 100 ns  - t4 40 ns max ("data access time after SCLK falling edge")
#                         - Pmod AD1 NL27WZ17 Schmitt buffer 6.5 ns max
#                         - 100 ohm series R into ~20 pF ~ 2 ns
#                         - FPGA clock-to-out of adc_sclk_o (FF + OBUF, ~5 ns)
#                         - FPGA input path of adc_d0_i (IBUF + route + FF setup, ~3 ns)
#                        ~= 43 ns margin at 10 MHz (23 ns at 12.5 MHz with
#                        G_SCLK_HALF_TICKS = 4; the Pmod must NOT run at 20 MHz,
#                        where this margin is ~0: ad7476a-pmodad1 report section 3).
#   * Hold side: the previous bit is held >= t7 = 10 ns min ("SCLK to data valid
#     hold time", 9.5 ns for VDD > 3.3 V) after the SCLK falling edge at the ADC,
#     which itself appears ~2-5 ns (clock-to-out) after the fabric edge that
#     captures. Hold margin ~= t7 + clock-to-out(min) + buffer(min) ~= 13 ns or more.
#   * t2 (CS falling to first SCLK falling) = 100 ns >= 10 ns; t1 (CS high) and
#     t8 + tQUIET (36 + 50 ns) are covered by the 350 ns CS-high gap; t5/t6
#     (SCLK low/high >= 0.4 tSCLK) = 50/50 ns.
#
# DAC write, DAC121S101 (fSCLK max 30 MHz; SPI mode 1: master launches on the
# SCLK rising edge, DAC latches DIN on the falling edge):
#   * tSUD (DIN valid before SCLK falling) >= 5 ns:  budget 50 ns - pin skew.
#   * tDHD (DIN held after SCLK falling)   >= 4.5 ns: budget 50 ns - pin skew.
#   * tSUCL (SYNC falling to first SCLK rising) >= 0 ns: budget 50 ns.
#   * tCS (16th falling edge to SYNC rising) >= 1 ns: budget 50 ns.
#   * tSYNC (SYNC high between frames) >= 20 ns: budget ~8.3 us.
#   * tH / tL (SCLK high / low) >= 13 ns: 50 ns each.
#   The only on-chip quantity in these budgets is the pin-to-pin skew between
#   outputs launched from the same clock edge in the same bank (same FF -> OBUF
#   structure, same IOSTANDARD/DRIVE/SLEW): ~1-2 ns. Every margin stays > 40 ns.
#
# LEDs: 1 Hz / ~2 Hz indicators, no timing requirement at all.
################################################################################
set_false_path -to   [get_ports {adc_cs_n_o[0] adc_sclk_o dac_sync_n_o[0] dac_sclk_o dac_dina_o dac_dinb_o led_o[*]}]
set_false_path -from [get_ports {adc_d0_i adc_d1_i}]

################################################################################
# 3. Debug: the ILA cores are instantiated in kr260_top.vhd; Vivado inserts the
#    debug hub (dbg_hub) during implementation and connects it to the only fabric
#    clock (clk_100m, the clk_wiz_0 output). The ILA IP ships its own timing
#    exceptions for the JTAG/BSCAN side. build.tcl prints the hub's clock after
#    implementation as a check.
################################################################################

################################################################################
# 4. Bitstream options.
#    * COMPRESS: shorter JTAG programming and a smaller .bit.bin for dfx-mgr.
#    * CFGBVS / CONFIG_VOLTAGE: NOT applicable on Zynq UltraScale+ MPSoC - the PL
#      is configured by the PS through PCAP, there is no dedicated configuration
#      bank. Vivado 2025.2 reports "[Vivado 12-5460] The attribute CFGBVS is not
#      supported in the xck26-sfvc784-2LV-c device" (checked), so they are
#      deliberately absent here.
################################################################################
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
