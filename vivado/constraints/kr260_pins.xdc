################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# NOTE: adc_cs_n_o and dac_sync_n_o are 1-bit vectors ([0]) because the block-design
#       wrapper exposes the AXI Quad SPI ss_o[0:0] pins; all other SPI ports are scalars.
# @brief   Pin constraints (PACKAGE_PIN / IOSTANDARD / drive / pulls) for kr260_top.
# @details Every pin below was cross-checked against three official
#          sources were compared pin for pin:
#            [B] Vivado 2025.2 board files kr260_carrier/1.0/board.xml
#                (pmodN_pinM -> som240_x_yy, iostandard="LVCMOS33") and
#                kr260_som/1.1/part0_pins.xml (som240_x_yy -> package pin),
#            [X] AMD XTP685 "Kria K26 SOM XDC" Rev 1 (som240 -> package pin,
#                bank, VCCO pin; 0 mismatches against [B]),
#            [U] UG1091 v1.2 / DS987 v1.5 SOM240 tables (HDAxx net names) and the
#                official KR260 platform XDCs (Xilinx/kria-vitis-platforms), which
#                constrain exactly these pins as LVCMOS33.
#          Status: ALL pins used here are AGREE (identical in [B], [X] and [U]).
#          Nothing is in a weaker state. What still needs the bench is listed at
#          the end of this file (module orientation in the 2x6 socket, LED
#          polarity, free-running 25 MHz clock) - none of it is a pin number.
#          Electrical rules:
#            * Pmod signals: bank 45 (HDIO), VCCO_HDA = 3.3 V -> LVCMOS33.
#            * Outputs SLEW SLOW / DRIVE 8 (official AMD Pmod XDCs use SLOW/4;
#              8 gives slightly crisper edges for the oscilloscope picture).
#            * PULLUP on the two active-low selects (adc_cs_n_o, dac_sync_n_o):
#              "CS must not float while the FPGA boots". Note that the pull-up
#              acts once the bitstream is loaded; before that (power-up until
#              Linux/dfx-mgr programs the PL) the HDIO pins are tri-stated. The
#              AD7476A tolerates that: the first two frames after reset are
#              discarded (G_DISCARD_FRAMES) and wake the part if it powered up
#              in power-down. On UltraScale+ "PULLUP true" is stored as
#              PULLTYPE PULLUP (checked in Vivado 2025.2).
#            * 25 MHz carrier clock and user LEDs: bank 66 (HPIO), VCCO_HPA =
#              1.8 V -> LVCMOS18 (never LVCMOS33 on this bank).
################################################################################

################################################################################
# Pmod AD1 (2x AD7476A) on PMOD1 = J2, UPPER row (odd header pins 1,3,5,7 = IO1..IO4)
# Digilent J1: 1 = CS, 2 = D0 (ADC A, A0 input), 3 = D1 (ADC B, A1 input), 4 = SCK,
#              5 = GND (header pin 9), 6 = VCC 3V3 (header pin 11)
# port          package  net    SOM240       header   status
# adc_cs_n_o    H12      HDA11  som240_1_a17 J2 pin 1 AGREE [B][X][U]
# adc_d0_i      E10      HDA12  som240_1_d20 J2 pin 3 AGREE [B][X][U]
# adc_d1_i      D10      HDA13  som240_1_d21 J2 pin 5 AGREE [B][X][U]
# adc_sclk_o    C11      HDA14  som240_1_d22 J2 pin 7 AGREE [B][X][U]
################################################################################
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true} [get_ports {adc_cs_n_o[0]}]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33}                               [get_ports adc_d0_i]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33}                               [get_ports adc_d1_i]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8}             [get_ports adc_sclk_o]
# No pulls on adc_d0_i / adc_d1_i: on the Pmod AD1 both data lines are driven by
# the NL27WZ17 Schmitt buffer (+100 ohm) and never float (ad7476a-pmodad1 report 1.5).

################################################################################
# Pmod DA2 (2x DAC121S101) on PMOD2 = J18, UPPER row (odd header pins 1,3,5,7 = IO1..IO4)
# Digilent J1: 1 = ~SYNC, 2 = DINA (-> VOUTA = J2 pin 1 = the loop source),
#              3 = DINB (-> VOUTB), 4 = SCLK, 5 = GND (header pin 9), 6 = VCC (header pin 11)
# port          package  net    SOM240       header    status
# dac_sync_n_o  J11      HDA02  som240_1_d18 J18 pin 1 AGREE [B][X][U]
# dac_dina_o    J10      HDA03  som240_1_b16 J18 pin 3 AGREE [B][X][U]
# dac_dinb_o    K13      HDA04  som240_1_b17 J18 pin 5 AGREE [B][X][U]
# dac_sclk_o    K12      HDA05  som240_1_b18 J18 pin 7 AGREE [B][X][U]
################################################################################
set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true} [get_ports {dac_sync_n_o[0]}]
set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8}             [get_ports dac_dina_o]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8}             [get_ports dac_dinb_o]
set_property -dict {PACKAGE_PIN K12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8}             [get_ports dac_sclk_o]

################################################################################
# Free-running 25 MHz carrier clock HPA_CLK0_P (Si5332 oscillator, GEM2 PHY reference)
# port          package  net         SOM240      bank  status
# clk_25m_i     C3       HPA_CLK0_P  som240_1_a6 66 GC AGREE [B][X][U] (official TSN XDC:
#               "# 25Mhz clock / PACKAGE_PIN C3 / IOSTANDARD LVCMOS18")
# IO_L12P_T1U_N10_GC_66: global-clock-capable pin, drives the MMCM of bank 66 directly.
################################################################################
set_property -dict {PACKAGE_PIN C3 IOSTANDARD LVCMOS18} [get_ports clk_25m_i]

################################################################################
# Carrier user LEDs (board.xml component "User_led" -> som240_1_d13/d14 -> F8/E8, LVCMOS18)
# port          package  SOM240       status
# led_o[0]      F8       som240_1_d13 AGREE [B][X]   heartbeat 1 Hz
# led_o[1]      E8       som240_1_d14 AGREE [B][X]   toggles every 2^18 ADC frames (~0.5 s)
################################################################################
set_property -dict {PACKAGE_PIN F8 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led_o[0]}]
set_property -dict {PACKAGE_PIN E8 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led_o[1]}]

################################################################################
# Optional: pack the SPI pin flip-flops into the IOB for deterministic pin skew.
# Left disabled on purpose: the demo_top debug copies may share the output
# register (fanout 2), in which case Vivado cannot pack and only warns. At
# 10 MHz SPI the fabric-to-pin skew (~1-2 ns within one bank) is irrelevant
# against the 50 ns half period (see kr260_timing.xdc). Enable if a scope
# measurement ever asks for it.
# set_property IOB TRUE [get_ports {adc_cs_n_o[0] adc_sclk_o adc_d0_i adc_d1_i dac_sync_n_o[0] dac_sclk_o dac_dina_o dac_dinb_o}]

################################################################################
# BENCH CHECKLIST (not pin values, but assumptions behind this file):
#  1. Both 1x6 modules sit in the UPPER row of their 2x6 socket: header pin 1 (IO1)
#     at one end, GND/3V3 (header pins 9/11) at the other. Measure GND and 3.3 V on
#     the two end pins of the chosen row with a meter BEFORE plugging a module in
#     (README.md, wiring table). Lower-row alternative for PMOD1: B10, E12, D11, B11.
#  2. LED polarity is assumed active-high (LED on = '1'); the heartbeat is visible
#     either way, only the duty picture flips.
#  3. The 25 MHz clock is modelled as fixed-clock in the Linux device tree, i.e.
#     expected to run without Linux; the heartbeat LED after a cold power-up is
#     the test (kr260-pins report, open question 4).
#  4. An AMD-forum user reports an RC network on header pins 1/2 of each Pmod
#     socket (schematic XTP743 is login-gated). Irrelevant at 10 MHz; if the ILA
#     or scope shows a slow edge on adc_cs_n_o / dac_sync_n_o, that is the cause.
################################################################################
