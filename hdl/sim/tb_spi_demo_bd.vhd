--------------------------------------------------------------------------------
--! Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
--! @file    tb_spi_demo_bd.vhd
--! @author  Marek Palka
--! @date    2026-10-13
--! @brief   xsim closed-loop testbench for the block design (MicroBlaze running
--!          spi_demo.elf + 2x AXI Quad SPI) with the behavioural chip models.
--! @details DUT = spi_demo_bd_wrapper. Pmod DA2 model (DAC-A) analog output is
--!          wired to the Pmod AD1 model (ADC-0) input = the jumper. ADC-1 sees a
--!          constant 1.0 V. The testbench decodes MISO exactly like a mode-2 SPI
--!          master (sample on the SCLK falling edge) and checks per ADC frame:
--!            * exactly 16 SCLK falling edges while CS is low
--!            * 4 leading zeros, then the 12-bit code of the DAC voltage (+/-1 LSB)
--!          and per DAC frame: 16 falling edges while SYNC is low, PD1 PD0 = 00,
--!          the code sequence follows the 100-point sine of spi_demo.c.
--!          The MicroBlaze view (mirror GPIO word) is checked from the Tcl side
--!          (sim_closed_loop.tcl, get_value on the mirror net) because the
--!          software only writes it after each frame.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_spi_demo_bd is
  generic (
    G_RUN_US     : natural := 600;      -- simulated time (summary printed at this time)
    G_VERBOSE    : boolean := false
  );
end entity tb_spi_demo_bd;

architecture sim of tb_spi_demo_bd is

  component spi_demo_bd_wrapper is
    port (
      adc_cs_n_o   : out std_logic_vector(0 to 0);   -- 1-bit vector in the wrapper (ss_o[0:0])
      adc_d0_i     : in  std_logic;
      adc_d1_i     : in  std_logic;
      adc_sclk_o   : out std_logic;
      clk_25m_i    : in  std_logic;
      dac_dina_o   : out std_logic;
      dac_dinb_o   : out std_logic;
      dac_sclk_o   : out std_logic;
      dac_sync_n_o : out std_logic_vector(0 to 0);
      led_o        : out std_logic_vector(1 downto 0)
    );
  end component;

  constant C_VREF : real := 3.3;

  signal clk_25m    : std_logic := '0';
  signal adc_cs_n, adc_sclk, adc_d0, adc_d1 : std_logic;
  signal adc_cs_n_v, dac_sync_n_v : std_logic_vector(0 to 0);
  signal dac_sync_n, dac_sclk, dac_dina, dac_dinb : std_logic;
  signal led        : std_logic_vector(1 downto 0);

  signal vout       : real := 0.0;          -- DAC-A analog out = ADC-0 analog in (the jumper)
  signal vin1       : real := 1.0;          -- ADC-1 input
  signal report_strobe : std_logic := '0';

  signal dac_reg    : std_logic_vector(11 downto 0);
  signal dac_frame  : std_logic_vector(15 downto 0);
  signal dac_frame_valid : std_logic;
  signal dac_mode   : std_logic_vector(1 downto 0);
  signal dac_frames, dac_err, dac_warn, dacb_frames, dacb_err, dacb_warn : natural;
  signal adc0_frames, adc0_err, adc0_warn, adc1_frames, adc1_err, adc1_warn : natural;
  signal adc0_pd, adc1_pd : std_logic;

  -- testbench bookkeeping
  signal tb_adc_frames_ok, tb_adc_frames_bad, tb_adc_edge_errors : natural := 0;
  signal tb_dac_frames_ok, tb_dac_frames_bad : natural := 0;
  signal tb_max_err_lsb : natural := 0;
  signal tb_zero_errors : natural := 0;
  signal done : boolean := false;

  function volts_to_code(v : real) return integer is
    variable c : integer;
  begin
    c := integer(floor(v / (C_VREF / 4096.0)));
    if c < 0 then c := 0; end if;
    if c > 4095 then c := 4095; end if;
    return c;
  end function;

  function sine_code(k : natural) return natural is
  begin
    return natural(round(2048.0 + 1792.0 * sin(2.0 * MATH_PI * real(k) / 100.0)));
  end function;

begin

  clk_25m <= not clk_25m after 20 ns;   -- 25 MHz carrier oscillator

  dut : spi_demo_bd_wrapper
    port map (
      adc_cs_n_o => adc_cs_n_v, adc_d0_i => adc_d0, adc_d1_i => adc_d1, adc_sclk_o => adc_sclk,
      clk_25m_i => clk_25m, dac_dina_o => dac_dina, dac_dinb_o => dac_dinb, dac_sclk_o => dac_sclk,
      dac_sync_n_o => dac_sync_n_v, led_o => led);
  adc_cs_n   <= adc_cs_n_v(0);
  dac_sync_n <= dac_sync_n_v(0);

  u_dac_a : entity work.dac121s101_model
    generic map (G_VA_V => C_VREF, G_SETTLE_NS => 2000, G_NAME => "DAC-A", G_VERBOSE => G_VERBOSE)   -- 2 us: realistic for the ~90 mV sine steps (datasheet 8-10 us is the half-scale figure)
    port map (
      sync_n_i => dac_sync_n, sclk_i => dac_sclk, din_i => dac_dina, analog_out => vout, report_i => report_strobe,
      frame_o => dac_frame, frame_valid_o => dac_frame_valid, dac_code_o => dac_reg, mode_o => dac_mode,
      analog_code_o => open, frame_count_o => dac_frames, error_count_o => dac_err, warn_count_o => dac_warn);

  u_dac_b : entity work.dac121s101_model
    generic map (G_VA_V => C_VREF, G_SETTLE_NS => 2000, G_NAME => "DAC-B", G_VERBOSE => false)
    port map (
      sync_n_i => dac_sync_n, sclk_i => dac_sclk, din_i => dac_dinb, analog_out => open, report_i => report_strobe,
      frame_o => open, frame_valid_o => open, dac_code_o => open, mode_o => open,
      analog_code_o => open, frame_count_o => dacb_frames, error_count_o => dacb_err, warn_count_o => dacb_warn);

  u_adc_0 : entity work.ad7476a_model
    generic map (G_VREF_V => C_VREF, G_START_IN_PD => true, G_PMOD_BUFFER => true, G_BUF_DELAY_NS => 7,
                 G_NAME => "ADC-0", G_VERBOSE => G_VERBOSE)
    port map (
      analog_in => vout, cs_n_i => adc_cs_n, sclk_i => adc_sclk, sdata_o => adc_d0, report_i => report_strobe,
      power_down_o => adc0_pd, frame_count_o => adc0_frames, error_count_o => adc0_err, warn_count_o => adc0_warn);

  u_adc_1 : entity work.ad7476a_model
    generic map (G_VREF_V => C_VREF, G_START_IN_PD => true, G_PMOD_BUFFER => true, G_BUF_DELAY_NS => 7,
                 G_NAME => "ADC-1", G_VERBOSE => false)
    port map (
      analog_in => vin1, cs_n_i => adc_cs_n, sclk_i => adc_sclk, sdata_o => adc_d1, report_i => report_strobe,
      power_down_o => adc1_pd, frame_count_o => adc1_frames, error_count_o => adc1_err, warn_count_o => adc1_warn);

  -- ADC frames: decode MISO like a mode-2 master (sample on the falling edge of SCLK)
  p_adc_check : process
    variable word     : std_logic_vector(15 downto 0);
    variable n_edges  : natural;
    variable v_cs     : real;
    variable expected : integer;
    variable got      : integer;
    variable diff     : natural;
    variable frames   : natural := 0;
  begin
    wait until falling_edge(adc_cs_n);
    v_cs := vout;                              -- sampled at the CS falling edge (track-and-hold)
    n_edges := 0;
    word := (others => '0');
    loop
      wait until falling_edge(adc_sclk) or rising_edge(adc_cs_n);
      exit when adc_cs_n = '1';
      if n_edges < 16 then
        word := word(14 downto 0) & to_x01(adc_d0);
      end if;
      n_edges := n_edges + 1;
    end loop;
    frames := frames + 1;
    if frames > 2 then                         -- skip the first frames: wake-up (dummy) conversions
    if n_edges /= 16 then
      tb_adc_edge_errors <= tb_adc_edge_errors + 1;
      report "ADC frame with " & integer'image(n_edges) & " SCLK falling edges (expected 16)" severity error;
    end if;
    if word(15 downto 12) /= "0000" then
      tb_zero_errors <= tb_zero_errors + 1;
      report "ADC frame without 4 leading zeros: " & integer'image(to_integer(unsigned(word))) severity error;
    end if;
    expected := volts_to_code(v_cs);
    got := to_integer(unsigned(word(11 downto 0)));
    diff := abs(expected - got);
    if diff > tb_max_err_lsb then tb_max_err_lsb <= diff; end if;
    if diff <= 1 and n_edges = 16 and word(15 downto 12) = "0000" then
      tb_adc_frames_ok <= tb_adc_frames_ok + 1;
    else
      tb_adc_frames_bad <= tb_adc_frames_bad + 1;
      report "ADC frame mismatch: DAC voltage " & real'image(v_cs) & " V -> expected code " & integer'image(expected)
             & ", MISO word gives " & integer'image(got) severity error;
    end if;
    if G_VERBOSE then
      report "ADC frame " & integer'image(frames) & ": vin " & real'image(v_cs) & " V, code " & integer'image(got) severity note;
    end if;
    end if;
  end process;

  -- DAC frames: 16 falling edges while SYNC low, normal mode, sine sequence
  p_dac_check : process
    variable n_edges : natural;
    variable k       : integer := -1;
    variable relocked : natural := 0;
    variable code    : natural;
    variable ok      : boolean;
  begin
    wait until falling_edge(dac_sync_n);
    n_edges := 0;
    loop
      wait until falling_edge(dac_sclk) or rising_edge(dac_sync_n);
      exit when dac_sync_n = '1';
      n_edges := n_edges + 1;
    end loop;
    wait for 1 ns;
    code := to_integer(unsigned(dac_reg));
    ok := (n_edges = 16) and (dac_mode = "00");
    if k < 0 then
      -- lock onto the sine table: FIRST match (2048 occurs at index 0 and 50; the program starts at 0)
      for i in 0 to 99 loop
        if k < 0 and sine_code(i) = code then k := i; end if;
      end loop;
      if k < 0 then ok := false; report "DAC code " & integer'image(code) & " is not in the sine table" severity error; end if;
    else
      k := (k + 1) mod 100;
      if sine_code(k) /= code then
        -- one re-lock allowed (ambiguous start value), then it is an error
        if relocked = 0 and sine_code((k + 49) mod 100) = code then
          k := (k + 49) mod 100; relocked := 1;
          report "DAC sequence: re-locked onto table index " & integer'image(k) severity note;
        else
          ok := false;
          report "DAC sequence error: expected " & integer'image(sine_code(k)) & " got " & integer'image(code) severity error;
        end if;
      end if;
    end if;
    if ok then tb_dac_frames_ok <= tb_dac_frames_ok + 1; else tb_dac_frames_bad <= tb_dac_frames_bad + 1; end if;
  end process;

  p_end : process
  begin
    wait for G_RUN_US * 1 us;
    report_strobe <= '1';
    wait for 10 ns;
    report "==================== tb_spi_demo_bd summary ====================" severity note;
    report "DAC-A frames " & integer'image(dac_frames) & " (tb ok " & integer'image(tb_dac_frames_ok) & ", bad "
           & integer'image(tb_dac_frames_bad) & "), DAC-B frames " & integer'image(dacb_frames)
           & ", model errors " & integer'image(dac_err + dacb_err) severity note;
    report "ADC-0 frames " & integer'image(adc0_frames) & " (tb ok " & integer'image(tb_adc_frames_ok) & ", bad "
           & integer'image(tb_adc_frames_bad) & ", edge errors " & integer'image(tb_adc_edge_errors)
           & ", leading-zero errors " & integer'image(tb_zero_errors) & ", max |err| " & integer'image(tb_max_err_lsb)
           & " LSB), model errors " & integer'image(adc0_err + adc1_err) & ", ADC-1 frames " & integer'image(adc1_frames) severity note;
    report "LEDs: " & std_logic'image(led(1)) & std_logic'image(led(0)) severity note;
    if tb_adc_frames_ok >= 20 and tb_adc_frames_bad = 0 and tb_adc_edge_errors = 0 and tb_zero_errors = 0
       and tb_dac_frames_ok >= 5 and tb_dac_frames_bad = 0 and (dac_err + dacb_err + adc0_err + adc1_err) = 0 then
      report "TB RESULT: PASS (tb_spi_demo_bd)" severity note;
    else
      report "TB RESULT: FAIL (tb_spi_demo_bd)" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
