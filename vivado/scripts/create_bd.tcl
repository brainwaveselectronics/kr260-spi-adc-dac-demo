################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# @brief   Builds the IP-integrator block design spi_demo_bd: MicroBlaze +
#          2x AXI Quad SPI (standard catalog IP) + GPIO mirror/LED + 2 System
#          ILAs, clocked from the KR260 carrier's 25 MHz oscillator (no PS).
# @details Sourced by create_project.tcl with the project open (the VHDL file
#          hdl/rtl/heartbeat.vhd must already be in sources_1 - it is used as a
#          module reference). Can also be sourced in an open project by hand.
#          Everything here is standard Vivado 2025.2 IPI Tcl; the only RTL is
#          the 1 Hz heartbeat. Addresses are fixed (sw/spi_demo.c relies on them):
#              axi_quad_spi_adc 0x44A0_0000   axi_quad_spi_dac 0x44A1_0000
#              axi_gpio_mirror  0x4000_0000   axi_gpio_led     0x4001_0000
#          External ports keep the names of vivado/constraints/kr260_pins.xdc.
#          Net names are chosen deliberately: they become the ILA probe names
#          in the Hardware Manager (adc_cs_n, adc_sclk, adc_miso, ...).
################################################################################
if {![info exists bd_name]} { set bd_name "spi_demo_bd" }

proc bd_msg {lvl txt} { puts "\[create_bd $lvl\] $txt" }

# ------------------------------------------------------------------------------
# 0. Design
# ------------------------------------------------------------------------------
create_bd_design $bd_name
current_bd_design $bd_name

# ------------------------------------------------------------------------------
# 1. Clock: 25 MHz carrier oscillator (pin C3) -> MMCM -> 100 MHz + locked
# ------------------------------------------------------------------------------
create_bd_port -dir I -type clk -freq_hz 25000000 clk_25m_i
set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ              {25.000} \
    CONFIG.PRIM_SOURCE               {Single_ended_clock_capable_pin} \
    CONFIG.PRIMITIVE                 {MMCM} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.USE_LOCKED                {true} \
    CONFIG.USE_RESET                 {false} \
    CONFIG.USE_SAFE_CLOCK_STARTUP    {false}] $clk_wiz
connect_bd_net -net clk_25m [get_bd_ports clk_25m_i] [get_bd_pins clk_wiz_0/clk_in1]

# constant 0 (no external reset source, unused SPI input pins)
set gnd [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_gnd]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $gnd

# ------------------------------------------------------------------------------
# 2. MicroBlaze + local memory + debug (MDM with JTAG UART) via automation
# ------------------------------------------------------------------------------
set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 microblaze_0]
apply_bd_automation -rule xilinx.com:bd_rule:microblaze -config [list \
    preset "Microcontroller" local_mem "64KB" ecc "None" cache "None" \
    debug_module "Debug & UART" axi_periph "Enabled" axi_intc "0" \
    clk "/clk_wiz_0/clk_out1 (100 MHz)"] $mb
# The automation adds a proc_sys_reset for the 100 MHz clock: find it, feed it
# with the MMCM lock and tie its external reset input off (power-on behaviour).
set rst_cells [get_bd_cells -filter {VLNV =~ "xilinx.com:ip:proc_sys_reset:*"}]
if {[llength $rst_cells] == 0} {
    set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_clk_100]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins rst_clk_100/slowest_sync_clk]
    connect_bd_net [get_bd_pins rst_clk_100/mb_reset] [get_bd_pins microblaze_0/Reset]
} else {
    set rst [lindex $rst_cells 0]
}
set rst_name [get_property NAME $rst]
bd_msg INFO "reset block: $rst_name"
# Reset polarity. proc_sys_reset's IP Tcl PROPAGATES C_EXT_RESET_HIGH from the
# polarity of the pin that drives ext_reset_in; a constant or a clock-wizard pin
# has none, so validation turned a user value of 1 into 0 (= active-low) and the
# block stayed in reset forever (xsim, 13/14 Oct 2026). Therefore:
#   * both polarity parameters are pinned with VALUE_SRC USER,
#   * ext_reset_in is driven by the MMCM "locked" signal with ACTIVE-LOW semantics
#     (not locked = 0 = reset, locked = 1 = run) - the only reset source the bare
#     board has, and consistent with what propagation would choose anyway,
#   * aux_reset_in is ACTIVE-HIGH and tied to 0.
# A check after validate_bd_design aborts the script if propagation changed it.
# C_EXT_RESET_HIGH cannot be set by the user at all (IPI derives it from the
# polarity of the driving pin at validation; user values are ignored). The
# ext_reset_in driver is clk_wiz_0/locked; after validate_bd_design the script
# reads the propagated polarity and, if it is ever "active high", inserts an
# inverter (NOT locked) so that "not locked = reset" holds in both cases.
set_property CONFIG.C_AUX_RESET_HIGH {1} $rst
bd_msg INFO "reset block: aux_reset_in active high (set), ext_reset_in polarity decided by propagation"

# (the automation may already have connected these two - connect only if still open)
proc bd_connect_if_open {pin src} {
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]] == 0} {
        connect_bd_net [get_bd_pins $src] [get_bd_pins $pin]
        bd_msg INFO "connected $src -> $pin"
    } else {
        bd_msg INFO "$pin already connected (automation)"
    }
}
bd_connect_if_open $rst_name/dcm_locked   clk_wiz_0/locked
# ext_reset_in <- locked (active-low ext reset, see above); disconnect whatever the automation put there
set ext_net [get_bd_nets -quiet -of_objects [get_bd_pins $rst_name/ext_reset_in]]
if {$ext_net ne ""} { disconnect_bd_net $ext_net [get_bd_pins $rst_name/ext_reset_in] }
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins $rst_name/ext_reset_in]
bd_connect_if_open $rst_name/aux_reset_in const_gnd/dout

# ------------------------------------------------------------------------------
# 3. Peripherals: 2x AXI Quad SPI (standard mode, 16-bit, manual SS, SCLK = 100/16 MHz),
#    GPIO mirror (32-bit out), GPIO LED (1-bit out)
# ------------------------------------------------------------------------------
foreach qspi {axi_quad_spi_adc axi_quad_spi_dac} {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi:3.2 $qspi]
    set_property -dict [list \
        CONFIG.C_SPI_MODE               {0} \
        CONFIG.C_TYPE_OF_AXI4_INTERFACE {0} \
        CONFIG.C_NUM_TRANSFER_BITS      {16} \
        CONFIG.C_SCK_RATIO              {16} \
        CONFIG.C_NUM_SS_BITS            {1} \
        CONFIG.C_FIFO_DEPTH             {16} \
        CONFIG.C_USE_STARTUP            {0} \
        CONFIG.C_USE_STARTUP_INT        {0}] $c
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins $qspi/ext_spi_clk]
}
set gpio_m [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_mirror]
set_property -dict [list CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_GPIO_WIDTH {32} CONFIG.C_DOUT_DEFAULT {0x00000000} CONFIG.C_IS_DUAL {0}] $gpio_m
set gpio_l [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_led]
set_property -dict [list CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_GPIO_WIDTH {1} CONFIG.C_DOUT_DEFAULT {0x00000000} CONFIG.C_IS_DUAL {0}] $gpio_l

foreach {cell intf} {axi_quad_spi_adc AXI_LITE axi_quad_spi_dac AXI_LITE axi_gpio_mirror S_AXI axi_gpio_led S_AXI} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Clk_master {/clk_wiz_0/clk_out1 (100 MHz)} Clk_slave {Auto} Clk_xbar {Auto} \
        Master {/microblaze_0 (Periph)} Slave "/$cell/$intf" ddr_seg {Auto} \
        intc_ip {Auto} master_apm {0}] [get_bd_intf_pins $cell/$intf]
}

# ------------------------------------------------------------------------------
# 4. External SPI pins (plain ports, named nets -> ILA probe names)
#    Pmod AD1 on PMOD1: CS, D0 (MISO), D1, SCK  |  Pmod DA2 on PMOD2: ~SYNC, DINA, DINB, SCLK
# ------------------------------------------------------------------------------
create_bd_port -dir O adc_cs_n_o
create_bd_port -dir O adc_sclk_o
create_bd_port -dir I adc_d0_i
create_bd_port -dir I adc_d1_i
create_bd_port -dir O dac_sync_n_o
create_bd_port -dir O dac_sclk_o
create_bd_port -dir O dac_dina_o
create_bd_port -dir O dac_dinb_o

connect_bd_net -net adc_cs_n   [get_bd_pins axi_quad_spi_adc/ss_o]  [get_bd_ports adc_cs_n_o]
connect_bd_net -net adc_sclk   [get_bd_pins axi_quad_spi_adc/sck_o] [get_bd_ports adc_sclk_o]
connect_bd_net -net adc_miso   [get_bd_ports adc_d0_i] [get_bd_pins axi_quad_spi_adc/io1_i]
connect_bd_net -net dac_sync_n [get_bd_pins axi_quad_spi_dac/ss_o]  [get_bd_ports dac_sync_n_o]
connect_bd_net -net dac_sclk   [get_bd_pins axi_quad_spi_dac/sck_o] [get_bd_ports dac_sclk_o]
connect_bd_net -net dac_mosi   [get_bd_pins axi_quad_spi_dac/io0_o] [get_bd_ports dac_dina_o] [get_bd_ports dac_dinb_o]
# unused master-side inputs tied low (the DAC core has no MISO, the ADC core sends nothing)
foreach pin {axi_quad_spi_adc/io0_i axi_quad_spi_adc/sck_i axi_quad_spi_adc/ss_i \
             axi_quad_spi_dac/io0_i axi_quad_spi_dac/io1_i axi_quad_spi_dac/sck_i axi_quad_spi_dac/ss_i} {
    connect_bd_net [get_bd_pins const_gnd/dout] [get_bd_pins $pin]
}

# ------------------------------------------------------------------------------
# 5. LEDs: led_o[0] = 1 Hz RTL heartbeat (clock + bitstream alive even if the
#    CPU stops), led_o[1] = software "loop alive" (axi_gpio_led bit 0)
# ------------------------------------------------------------------------------
set hb [create_bd_cell -type module -reference heartbeat heartbeat_0]
set_property -dict [list CONFIG.G_CLK_HZ {100000000}] $hb
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins heartbeat_0/clk_i]
connect_bd_net [get_bd_pins $rst_name/peripheral_reset] [get_bd_pins heartbeat_0/rst_i]
connect_bd_net [get_bd_pins const_gnd/dout] [get_bd_pins heartbeat_0/sample_valid_i]
set hb_slice [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 slice_heartbeat]
set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {1}] $hb_slice
connect_bd_net [get_bd_pins heartbeat_0/led_o] [get_bd_pins slice_heartbeat/Din]
set led_cat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 concat_led]
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {1}] $led_cat
connect_bd_net [get_bd_pins slice_heartbeat/Dout]   [get_bd_pins concat_led/In0]
connect_bd_net -net led_sw [get_bd_pins axi_gpio_led/gpio_io_o] [get_bd_pins concat_led/In1]
create_bd_port -dir O -from 1 -to 0 led_o
connect_bd_net -net led [get_bd_pins concat_led/dout] [get_bd_ports led_o]

# ------------------------------------------------------------------------------
# 6. Debug: System ILA "spi" on the pin nets (4096 deep, trigger = CS falling)
#    and System ILA "wave" on the mirror GPIO (8192 deep, capture control on
#    the software valid-toggle bit -> one entry per ADC sample).
# ------------------------------------------------------------------------------
set ila_spi [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 ila_spi]
set_property -dict [list \
    CONFIG.C_MON_TYPE {NATIVE} CONFIG.C_NUM_OF_PROBES {7} CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_EN_STRG_QUAL {0} CONFIG.ALL_PROBE_SAME_MU {TRUE} CONFIG.ALL_PROBE_SAME_MU_CNT {1} \
    CONFIG.C_ADV_TRIGGER {FALSE} CONFIG.C_INPUT_PIPE_STAGES {0} \
    CONFIG.C_PROBE0_WIDTH {1} CONFIG.C_PROBE1_WIDTH {1} CONFIG.C_PROBE2_WIDTH {1} CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} CONFIG.C_PROBE5_WIDTH {1} CONFIG.C_PROBE6_WIDTH {1}] $ila_spi
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins ila_spi/clk]
connect_bd_net -net adc_cs_n   [get_bd_pins ila_spi/probe0]
connect_bd_net -net adc_sclk   [get_bd_pins ila_spi/probe1]
connect_bd_net -net adc_miso   [get_bd_pins ila_spi/probe2]
connect_bd_net -net adc_d1     [get_bd_ports adc_d1_i] [get_bd_pins ila_spi/probe3]
connect_bd_net -net dac_sync_n [get_bd_pins ila_spi/probe4]
connect_bd_net -net dac_sclk   [get_bd_pins ila_spi/probe5]
connect_bd_net -net dac_mosi   [get_bd_pins ila_spi/probe6]

# mirror word: [11:0] ADC sample, [23:12] DAC code, [24] valid toggle, [28:25] leading-zero nibble
set first_slice 1
foreach {name from to w} {slice_adc_sample 11 0 12  slice_dac_code 23 12 12  slice_valid 24 24 1  slice_zeros 28 25 4} {
    set s [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 $name]
    set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM $from CONFIG.DIN_TO $to CONFIG.DOUT_WIDTH $w] $s
    if {$first_slice} {
        connect_bd_net -net mirror [get_bd_pins axi_gpio_mirror/gpio_io_o] [get_bd_pins $name/Din]
        set first_slice 0
    } else {
        connect_bd_net -net mirror [get_bd_pins $name/Din]
    }
}
set ila_wave [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 ila_wave]
set_property -dict [list \
    CONFIG.C_MON_TYPE {NATIVE} CONFIG.C_NUM_OF_PROBES {4} CONFIG.C_DATA_DEPTH {8192} \
    CONFIG.C_EN_STRG_QUAL {1} CONFIG.ALL_PROBE_SAME_MU {TRUE} CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
    CONFIG.C_ADV_TRIGGER {FALSE} CONFIG.C_INPUT_PIPE_STAGES {0} \
    CONFIG.C_PROBE0_WIDTH {12} CONFIG.C_PROBE1_WIDTH {12} CONFIG.C_PROBE2_WIDTH {1} CONFIG.C_PROBE3_WIDTH {4}] $ila_wave
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins ila_wave/clk]
connect_bd_net -net adc_sample [get_bd_pins slice_adc_sample/Dout] [get_bd_pins ila_wave/probe0]
connect_bd_net -net dac_code   [get_bd_pins slice_dac_code/Dout]   [get_bd_pins ila_wave/probe1]
connect_bd_net -net adc_valid  [get_bd_pins slice_valid/Dout]      [get_bd_pins ila_wave/probe2]
connect_bd_net -net adc_zeros  [get_bd_pins slice_zeros/Dout]      [get_bd_pins ila_wave/probe3]

# ------------------------------------------------------------------------------
# 7. Addresses (fixed; sw/spi_demo.c uses them)
# ------------------------------------------------------------------------------
assign_bd_address
foreach {cell intf off} {axi_quad_spi_adc AXI_LITE 0x44A00000  axi_quad_spi_dac AXI_LITE 0x44A10000 \
                         axi_gpio_mirror  S_AXI    0x40000000  axi_gpio_led     S_AXI    0x40010000} {
    assign_bd_address -offset $off -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] \
        [get_bd_addr_segs $cell/$intf/Reg] -force
}
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data]] {
    bd_msg INFO "addr map: [get_property NAME $s] offset [get_property OFFSET $s] range [get_property RANGE $s]"
}

# ------------------------------------------------------------------------------
# 8. Validate, save, wrapper
# ------------------------------------------------------------------------------
regenerate_bd_layout
validate_bd_design
# Post-validation: adapt the ext_reset_in driver to the propagated polarity.
set e [get_property CONFIG.C_EXT_RESET_HIGH $rst]
set a [get_property CONFIG.C_AUX_RESET_HIGH $rst]
bd_msg INFO "after validation: $rst_name C_EXT_RESET_HIGH=$e C_AUX_RESET_HIGH=$a"
if {$a != 1} { error "aux reset polarity is $a, expected 1 (active high, tied to 0) - fix create_bd.tcl" }
if {$e == 1} {
    bd_msg WARNING "ext_reset_in propagated as ACTIVE HIGH - inserting NOT(locked) so that 'not locked' still means reset"
    disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $rst_name/ext_reset_in]] [get_bd_pins $rst_name/ext_reset_in]
    set inv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 not_locked]
    set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $inv
    connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins not_locked/Op1]
    connect_bd_net [get_bd_pins not_locked/Res] [get_bd_pins $rst_name/ext_reset_in]
    validate_bd_design
    set e2 [get_property CONFIG.C_EXT_RESET_HIGH $rst]
    bd_msg INFO "after re-validation with inverter: C_EXT_RESET_HIGH=$e2"
    if {$e2 != 1} { error "ext reset polarity flipped to $e2 after inserting the inverter - inconsistent, fix create_bd.tcl" }
} elseif {$e != 0} {
    error "unexpected C_EXT_RESET_HIGH value '$e'"
} else {
    bd_msg INFO "ext_reset_in <- locked with ACTIVE LOW polarity: not locked = reset, locked = run (verified)"
}
save_bd_design
set bd_file [get_files ${bd_name}.bd]
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse -fileset sources_1 $wrapper
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1
bd_msg INFO "block design $bd_name validated; wrapper ${bd_name}_wrapper is the top"
