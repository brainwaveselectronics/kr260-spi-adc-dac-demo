--------------------------------------------------------------------------------
-- Project: KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
-- @author  Marek Palka
-- @date    2026-10-13
-- @brief   Behavioural simulation model of the Analog Devices AD7476A 12-bit
--          1 MSPS SPI ADC (one of the two converters on the Digilent Pmod AD1).
-- @details Data sheet: AD7476A/AD7477A/AD7478A Rev. G (1/2016), Table 4 timing,
--          "Serial Interface" and "Modes of Operation" sections; see
--          the AD7476A datasheet (Rev. G, Table 4 and Figures 2-3) for the
--          verbatim quotes behind every rule below.
--
--          Frame (Figure 3/24), "F n" = n-th SCLK falling edge after CS fell:
--            CS falling : track-and-hold -> hold, analog_in sampled, conversion
--                         starts, bus leaves three-state and shows leading zero 1
--                         within t3 = 22 ns.
--            F1 .. F15  : launch leading zero 2, 3, 4, then DB11 (MSB) .. DB0.
--                         The previous bit is held for t7 = 10 ns after the edge,
--                         the new bit is valid t4 = 40 ns after the edge; the
--                         model drives 'X' in between so that a master sampling
--                         too early fails in simulation (that is the point).
--            F16        : SDATA goes three-state within t8 = 36 ns (bus relinquish).
--          A master that captures SDATA at the instant of each SCLK falling edge
--          (the fabric edge that produces it) therefore reads
--          "0000" & DB11..DB0 = raw16, sample = raw16(11 downto 0).
--
--          Protocol checks (reported with G_ERR_SEVERITY, default error, counted
--          in error_count_o): fSCLK max (period >= 1/G_FSCLK_MAX_HZ), t5/t6 duty
--          (>= 0.4 tSCLK), t2 (CS falling to F1 >= 10 ns), t1 (CS high >= 10 ns),
--          tQUIET (bus relinquish to next CS falling >= 50 ns), fewer than 16
--          falling edges per CS-low period, CS rising inside the power-down
--          window (after F2 and before F10 -> the part powers down, flag
--          power_down_o, next frame is a dummy conversion with invalid data),
--          analog input beyond the absolute maximum (VDD + 0.3 V).
--          Warnings (counted in warn_count_o): SCLK not idle-high at CS falling,
--          extra SCLK falling edges after F16, analog input outside 0..VDD.
--
--          Power-up: "the ADC can power up in either the power-down or normal
--          modes" -> G_START_IN_PD = true (pessimistic default). The first frame
--          is then a dummy conversion (all 16 bits 'X'); after its 16th SCLK the
--          part is powered and the next conversion is valid (Figure 22).
--
--          G_PMOD_BUFFER = true reproduces the Pmod AD1 data path (NL27WZ17
--          Schmitt buffer + 100 R, no pull resistor): the connector pin never
--          floats - it holds the last level when the ADC three-states - and
--          every edge is delayed by G_BUF_DELAY_NS. This is what the ILA will
--          show on hardware (MISO stays at DB0 after F16).
--
--          Not modelled: INL/DNL, noise, acquisition-time limits, tPOWER-UP as a
--          time (the 16-SCLK rule of the data sheet is used instead).
--          Simulation only.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.tb_pkg.all;

entity ad7476a_model is
  generic (
    G_VREF_V       : real           := 3.3;         -- VDD = reference, input range 0..VDD, LSB = VDD/4096
    G_T4_NS        : natural        := 40;          -- t4  data access time after SCLK falling edge, max
    G_T3_NS        : natural        := 22;          -- t3  CS falling to SDATA three-state disabled, max
    G_T7_NS        : natural        := 10;          -- t7  SCLK to data valid hold time, min (VDD <= 3.3 V)
    G_T8_NS        : natural        := 36;          -- t8  SCLK falling (F16) to SDATA high impedance, max
    G_T1_NS        : natural        := 10;          -- t1  minimum CS pulse width (high), min
    G_T2_NS        : natural        := 10;          -- t2  CS falling to first SCLK falling, min
    G_T_QUIET_NS   : natural        := 50;          -- tQUIET bus relinquish to next CS falling, min
    G_FSCLK_MAX_HZ : positive       := 20_000_000;  -- fSCLK max (one value for 2.35..5.25 V)
    G_DUTY_MIN     : real           := 0.4;         -- t5/t6 >= 0.4 tSCLK (Table 4 footnote 2: 40/60 .. 60/40)
    G_START_IN_PD  : boolean        := true;        -- power up in power-down mode (pessimistic)
    G_PMOD_BUFFER  : boolean        := false;       -- true: Pmod AD1 Schmitt buffer, pin holds last level instead of 'Z'
    G_BUF_DELAY_NS : natural        := 0;           -- extra data-path delay (Pmod AD1: NL27WZ17 + 100 R, about 4..7 ns)
    G_NAME         : string         := "AD7476A";   -- tag used in all messages
    G_VERBOSE      : boolean        := false;       -- note-level messages per frame
    G_MAX_REPORTS  : natural        := 50;          -- print at most this many error/warning messages (all are counted)
    G_ERR_SEVERITY : severity_level := error        -- severity of protocol errors (self-tests use warning)
  );
  port (
    analog_in     : in  real := 0.0;               -- VIN in volts (0.0 .. G_VREF_V)
    cs_n_i        : in  std_logic;
    sclk_i        : in  std_logic;
    sdata_o       : out std_logic := 'Z';
    -- bookkeeping for the testbench
    report_i      : in  std_logic := '0';          -- rising edge: print the summary
    power_down_o  : out std_logic := '0';          -- '1' while the part is in power-down
    frame_count_o : out natural   := 0;            -- completed 16-edge frames (incl. dummy conversions)
    error_count_o : out natural   := 0;
    warn_count_o  : out natural   := 0
  );
end entity ad7476a_model;

architecture sim of ad7476a_model is

  constant C_T1        : time := G_T1_NS * 1 ns;
  constant C_T2        : time := G_T2_NS * 1 ns;
  constant C_T3        : time := G_T3_NS * 1 ns;
  constant C_T4        : time := G_T4_NS * 1 ns;
  constant C_T7        : time := G_T7_NS * 1 ns;
  constant C_T8        : time := G_T8_NS * 1 ns;
  constant C_TQUIET    : time := G_T_QUIET_NS * 1 ns;
  constant C_TSCLK_MIN : time := 1 sec / G_FSCLK_MAX_HZ;   -- 50 ns at 20 MHz
  constant C_BUF       : time := G_BUF_DELAY_NS * 1 ns;

begin

  -- generic sanity (elaboration time)
  assert G_T7_NS < G_T4_NS
    report G_NAME & ": G_T7_NS (hold) must be smaller than G_T4_NS (access time)" severity failure;
  assert G_T7_NS <= G_T8_NS
    report G_NAME & ": G_T7_NS must not exceed G_T8_NS (t7 is the minimum of t8)" severity failure;
  assert G_VREF_V > 0.0
    report G_NAME & ": G_VREF_V must be positive" severity failure;
  assert G_DUTY_MIN > 0.0 and G_DUTY_MIN <= 0.5
    report G_NAME & ": G_DUTY_MIN must be in (0, 0.5]" severity failure;
  assert G_T4_NS * 1 ns < C_TSCLK_MIN
    report G_NAME & ": t4 must be shorter than the minimum SCLK period" severity failure;

  p_model : process (cs_n_i, sclk_i, report_i)
    -- mode / frame state
    variable powered       : boolean := not G_START_IN_PD;
    variable waking        : boolean := false;   -- current frame is the dummy conversion that powers the part up
    variable in_frame      : boolean := false;   -- CS low
    variable edge_cnt      : natural := 0;       -- SCLK falling edges since CS fell
    variable word          : std_logic_vector(15 downto 0) := (others => 'X');
    -- timestamps
    variable t_cs_fall     : time := 0 ns;
    variable t_cs_rise     : time := 0 ns;
    variable t_last_fall   : time := 0 ns;
    variable t_last_rise   : time := 0 ns;
    variable t_tristate    : time := 0 ns;       -- when SDATA (bare pin) goes/went three-state
    variable cs_rise_seen  : boolean := false;
    variable tristate_seen : boolean := false;
    variable rise_in_frame : boolean := false;   -- an SCLK rising edge occurred since the last falling edge
    variable extra_warned  : boolean := false;
    -- statistics
    variable n_frames      : natural := 0;
    variable n_aborted     : natural := 0;
    variable n_dummy       : natural := 0;
    variable n_pd          : natural := 0;
    variable n_err         : natural := 0;
    variable n_warn        : natural := 0;
    -- scratch
    variable vin           : real;
    variable code          : natural;
    variable per, lo, hi   : time;

    procedure err(msg : string) is
    begin
      n_err := n_err + 1;
      if n_err <= G_MAX_REPORTS then
        report G_NAME & " PROTOCOL ERROR: " & msg & "  (t = " & fmt_ns(now) & ")" severity G_ERR_SEVERITY;
      elsif n_err = G_MAX_REPORTS + 1 then
        report G_NAME & " PROTOCOL ERROR: more than " & natural'image(G_MAX_REPORTS) &
               " violations - further messages suppressed (still counted)  (t = " & fmt_ns(now) & ")" severity G_ERR_SEVERITY;
      end if;
    end procedure;

    procedure warn(msg : string) is
    begin
      n_warn := n_warn + 1;
      if n_warn <= G_MAX_REPORTS then
        report G_NAME & " warning: " & msg & "  (t = " & fmt_ns(now) & ")" severity warning;
      elsif n_warn = G_MAX_REPORTS + 1 then
        report G_NAME & " warning: more than " & natural'image(G_MAX_REPORTS) &
               " warnings - further messages suppressed (still counted)  (t = " & fmt_ns(now) & ")" severity warning;
      end if;
    end procedure;

    procedure note(msg : string) is
    begin
      if G_VERBOSE then
        report G_NAME & ": " & msg & "  (t = " & fmt_ns(now) & ")" severity note;
      end if;
    end procedure;

    -- F1..F15: the previous bit is guaranteed for t7 after the falling edge, the new bit
    -- is guaranteed t4 after it; in between the data sheet guarantees nothing -> 'X'.
    procedure launch_bit(b : std_logic) is
    begin
      sdata_o <= transport 'X' after C_T7 + C_BUF, b after C_T4 + C_BUF;
    end procedure;

    -- Bus relinquish (F16 or CS rising mid-frame): the bare pin holds the old bit for at
    -- least t_hold and is high impedance after t_z ("t7 values also apply to t8 minimum").
    -- Behind the Pmod AD1 Schmitt buffer the connector pin simply keeps its last level.
    procedure release_bus(t_hold : time; t_z : time) is
    begin
      if not G_PMOD_BUFFER then
        sdata_o <= transport 'X' after t_hold, 'Z' after t_z;
      end if;
    end procedure;

  begin

    ----------------------------------------------------------------------------
    -- summary on request
    ----------------------------------------------------------------------------
    if rising_edge(report_i) then
      report G_NAME & " SUMMARY: frames completed = " & natural'image(n_frames) &
             " (dummy/wake-up conversions = " & natural'image(n_dummy) & ")" &
             ", frames aborted by CS = " & natural'image(n_aborted) &
             ", power-down entries = " & natural'image(n_pd) &
             ", protocol errors = " & natural'image(n_err) &
             ", warnings = " & natural'image(n_warn) &
             ", powered now = " & boolean'image(powered)
        severity note;
    end if;

    ----------------------------------------------------------------------------
    -- CS falling edge: sample, start conversion, leading zero 1 (t3)
    ----------------------------------------------------------------------------
    if falling_edge(cs_n_i) then
      if to_x01(sclk_i) /= '1' then
        warn("SCLK is not high at the CS falling edge (Figure 3 defines the frame with SCLK idle high; t2 is measured to the first FALLING edge)");
      end if;
      if cs_rise_seen and (now - t_cs_rise) < C_T1 then
        err("t1 CS high pulse width " & fmt_ns(now - t_cs_rise) & " < " & fmt_ns(C_T1) & " min");
      end if;
      if tristate_seen and (now - t_tristate) < C_TQUIET then
        err("tQUIET " & fmt_ns(now - t_tristate) & " between bus relinquish and this CS falling edge < " &
            fmt_ns(C_TQUIET) & " min");
      end if;

      -- "The falling edge of CS puts the track-and-hold into hold mode ...; the analog input is sampled at this point."
      vin := analog_in;
      if vin < -0.3 or vin > G_VREF_V + 0.3 then
        err("analog input " & fmt_real(vin, 4) & " V beyond the absolute maximum rating (-0.3 V .. VDD + 0.3 V)");
      elsif vin < 0.0 or vin > G_VREF_V then
        warn("analog input " & fmt_real(vin, 4) & " V outside 0 .. VDD, code clamps");
      end if;
      code := volts_to_code(vin, G_VREF_V);

      if powered then
        -- "four leading zeros followed by 12 bits of conversion data that are provided MSB first"
        word := "0000" & std_logic_vector(to_unsigned(code, 12));
        note("CS fell: sampled " & fmt_real(vin, 4) & " V -> code " & natural'image(code) &
             " (" & hex(word) & ")");
      else
        -- "a dummy conversion is performed. On the falling edge of CS, the device begins to power up" (Figure 22: INVALID DATA)
        waking  := true;
        word    := (others => 'X');
        n_dummy := n_dummy + 1;
        note("CS fell while in power-down: dummy conversion (wake-up), data of this frame is invalid");
      end if;

      edge_cnt      := 0;
      in_frame      := true;
      rise_in_frame := false;
      extra_warned  := false;
      t_cs_fall     := now;
      -- "CS going low clocks out the first leading zero" - valid within t3 (three-state disable)
      sdata_o <= transport 'X' after C_BUF, word(15) after C_T3 + C_BUF;
    end if;

    ----------------------------------------------------------------------------
    -- CS rising edge: frame end, or termination / power-down decision
    ----------------------------------------------------------------------------
    if rising_edge(cs_n_i) and in_frame then
      in_frame     := false;
      cs_rise_seen := true;
      t_cs_rise    := now;
      if edge_cnt < 16 then
        n_aborted := n_aborted + 1;
        err("CS rose after only " & natural'image(edge_cnt) &
            " SCLK falling edge(s): conversion terminated, SDATA three-stated (16 edges required)");
        release_bus(0 ns, C_T8);
        t_tristate    := now + C_T8;
        tristate_seen := true;
        if edge_cnt >= 2 and edge_cnt <= 9 then
          -- "bringing CS high anywhere after the second falling edge of SCLK and before the 10th falling edge of SCLK"
          powered := false;
          n_pd    := n_pd + 1;
          err("CS rose inside the power-down window (after F2 and before F10): the part enters power-down; " &
              "the next frame is a dummy conversion with invalid data");
        elsif waking then
          if edge_cnt < 10 then
            -- "If CS is brought high before the 10th falling edge of SCLK, then the AD7476A ... go back into power-down."
            powered := false;
            note("wake-up frame terminated before F10: the part stays in power-down");
          else
            powered := true;
            note("wake-up frame terminated after F10: the part is powered up");
          end if;
        end if;
        -- edge_cnt < 2 and not waking: "the part remains in normal mode and does not power down" (glitch protection)
        waking := false;
      end if;
    end if;

    ----------------------------------------------------------------------------
    -- SCLK falling edge inside the frame: timing checks + bit launch
    ----------------------------------------------------------------------------
    if falling_edge(sclk_i) and in_frame then
      edge_cnt := edge_cnt + 1;

      if edge_cnt = 1 then
        if (now - t_cs_fall) < C_T2 then
          err("t2 CS falling to first SCLK falling edge " & fmt_ns(now - t_cs_fall) & " < " & fmt_ns(C_T2) & " min");
        end if;
      else
        per := now - t_last_fall;
        if per < C_TSCLK_MIN then
          err("SCLK period " & fmt_ns(per) & " < " & fmt_ns(C_TSCLK_MIN) & " (fSCLK max " &
              natural'image(G_FSCLK_MAX_HZ / 1_000_000) & " MHz)");
        end if;
        if rise_in_frame then
          lo := t_last_rise - t_last_fall;
          hi := now - t_last_rise;
          if lo < G_DUTY_MIN * per then
            err("t5 SCLK low pulse width " & fmt_ns(lo) & " < 0.4 tSCLK = " & fmt_ns(G_DUTY_MIN * per));
          end if;
          if hi < G_DUTY_MIN * per then
            err("t6 SCLK high pulse width " & fmt_ns(hi) & " < 0.4 tSCLK = " & fmt_ns(G_DUTY_MIN * per));
          end if;
        end if;
      end if;
      t_last_fall   := now;
      rise_in_frame := false;

      if edge_cnt <= 15 then
        -- F1 launches leading zero 2 = word(14) ... F4 launches DB11 = word(11) ... F15 launches DB0 = word(0)
        launch_bit(word(15 - edge_cnt));
      elsif edge_cnt = 16 then
        -- "On the 16th SCLK falling edge, the SDATA line goes back into three-state." (t8, min t7)
        release_bus(C_T7, C_T8);
        t_tristate    := now + C_T8;
        tristate_seen := true;
        n_frames      := n_frames + 1;
        if waking then
          -- "The device is fully powered up once 16 SCLKs have elapsed, and valid data results from the next conversion"
          powered := true;
          waking  := false;
          note("16 SCLK falling edges elapsed: the part is powered up, the next conversion is valid");
        end if;
      else
        if not extra_warned then
          warn("SCLK falling edge #" & natural'image(edge_cnt) &
               " after F16 while CS is low: ignored by the part (SDATA stays three-state)");
          extra_warned := true;
        end if;
      end if;
    end if;

    ----------------------------------------------------------------------------
    -- SCLK rising edge inside the frame: bookkeeping for the duty-cycle check
    ----------------------------------------------------------------------------
    if rising_edge(sclk_i) and in_frame then
      t_last_rise   := now;
      rise_in_frame := true;
    end if;

    ----------------------------------------------------------------------------
    -- status outputs (also executed once at time 0)
    ----------------------------------------------------------------------------
    if powered then
      power_down_o <= '0';
    else
      power_down_o <= '1';
    end if;
    frame_count_o <= n_frames;
    error_count_o <= n_err;
    warn_count_o  <= n_warn;
  end process p_model;

end architecture sim;
