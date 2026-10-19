--------------------------------------------------------------------------------
-- Project: KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
-- @author  Marek Palka
-- @date    2026-10-13
-- @brief   Behavioural simulation model of the TI DAC121S101 12-bit SPI DAC
--          (one of the two converters on the Digilent Pmod DA2).
-- @details Data sheet: TI SNAS265J (rev. Sept. 2015), sections 7.6 (timing,
--          Figure 2), 8.3.1 (transfer function), 8.4 (power-on / power-down),
--          8.5 (serial interface); see the DAC121S101 datasheet (SNAS265)
--          sections 3-5 for the verbatim quotes.
--
--          Frame: SYNC low, then 16 SCLK FALLING edges shift DIN into the input
--          register, MSB (DB15) first: X X PD1 PD0 D11..D0. "The contents of the
--          serial input register are transferred to the DAC register on the
--          sixteenth falling edge of SCLK." PD1 PD0 = 00 normal operation;
--          01 / 10 / 11 = power-down (1 kOhm / 100 kOhm to GND / Hi-Z).
--          VOUT = VA x D / 4096 (VA = supply = reference; 3.3 V on the Pmod).
--          Power-on state: DAC register 0, VOUT 0 V (8.4.1).
--
--          analog_out is a zero-order settling model: it keeps the old value for
--          G_SETTLE_NS after the 16th falling edge and then jumps to the new one.
--          Default = ts max over temperature for a half-scale step (10 us,
--          400h -> C00h, 2 kOhm || 200 pF). For the demo's <= 113 LSB steps the
--          real part settles far faster (1 V/us slew -> about 0.1 us) - the
--          testbench instantiates the model with a shorter value and documents it.
--          analog_code_o changes together with analog_out and is the exact code
--          the output represents (reference for the closed-loop check).
--
--          Protocol checks (reported with G_ERR_SEVERITY, counted in
--          error_count_o): SYNC rising before the 16th falling edge (write
--          ignored, 8.5.2), tSYNC SYNC high time (>= 20 ns at 2.7-3.6 V), SCLK
--          period (fSCLK <= 30 MHz), tH / tL (>= 13 ns over temperature),
--          tSUCL (SCLK rising edge must not precede the SYNC falling edge,
--          min 0 ns), tSUD / tDHD (DIN stable >= 5 ns before and >= 4.5 ns
--          after each latching falling edge), tCS (16th falling edge to SYNC
--          rising >= 1 ns at VA = 3 V), power-down mode bits received while
--          G_EXPECT_NORMAL is true, metavalues in a frame.
--          Warnings: empty SYNC pulse, SCLK falling edges after the 16th bit
--          while SYNC is still low (not defined by TI, avoided by construction).
--
--          Simulation only.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.tb_pkg.all;

entity dac121s101_model is
  generic (
    G_VA_V          : real           := 3.3;         -- VA = supply = reference
    G_SETTLE_NS     : natural        := 10_000;      -- ts output settling time, 10 us max (TMIN-TMAX, half-scale step)
    G_FSCLK_MAX_HZ  : positive       := 30_000_000;  -- fSCLK max
    G_TH_NS         : real           := 13.0;        -- tH SCLK high time, min over temperature
    G_TL_NS         : real           := 13.0;        -- tL SCLK low time, min over temperature
    G_TSUCL_NS      : real           := 0.0;         -- tSUCL SYNC falling to first SCLK rising, min over temperature
    G_TSUD_NS       : real           := 5.0;         -- tSUD DIN set-up before SCLK falling, min over temperature
    G_TDHD_NS       : real           := 4.5;         -- tDHD DIN hold after SCLK falling, min over temperature
    G_TCS_NS        : real           := 1.0;         -- tCS 16th SCLK falling to SYNC rising, min (VA = 3 V, over temperature)
    G_TSYNC_NS      : real           := 20.0;        -- tSYNC SYNC high time, min (2.7 <= VA <= 3.6 V, over temperature)
    G_EXPECT_NORMAL : boolean        := true;        -- PD1 PD0 /= 00 is an error unless a test wants power-down
    G_NAME          : string         := "DAC121S101";
    G_VERBOSE       : boolean        := false;       -- note-level message per frame
    G_MAX_REPORTS   : natural        := 50;          -- print at most this many error/warning messages (all are counted)
    G_ERR_SEVERITY  : severity_level := error        -- severity of protocol errors (self-tests use warning)
  );
  port (
    sync_n_i       : in  std_logic;
    sclk_i         : in  std_logic;
    din_i          : in  std_logic;
    analog_out     : out real := 0.0;                -- VOUT in volts, power-on 0 V
    -- bookkeeping / debug for the testbench
    report_i       : in  std_logic := '0';           -- rising edge: print the summary
    frame_o        : out std_logic_vector(15 downto 0) := (others => '0');  -- last complete word as received (DB15 first)
    frame_valid_o  : out std_logic := '0';           -- 1 ns pulse at the 16th SCLK falling edge
    dac_code_o     : out std_logic_vector(11 downto 0) := (others => '0');  -- DAC register (updates at the 16th falling edge)
    mode_o         : out std_logic_vector(1 downto 0) := "00";              -- PD1 PD0 of the last write
    analog_code_o  : out natural := 0;               -- code analog_out represents right now (follows analog_out)
    frame_count_o  : out natural := 0;
    error_count_o  : out natural := 0;
    warn_count_o   : out natural := 0
  );
end entity dac121s101_model;

architecture sim of dac121s101_model is

  constant C_SETTLE    : time := G_SETTLE_NS * 1 ns;
  constant C_TSCLK_MIN : time := 1 sec / G_FSCLK_MAX_HZ;   -- 33.333 ns at 30 MHz
  constant C_TH        : time := G_TH_NS * 1 ns;
  constant C_TL        : time := G_TL_NS * 1 ns;
  constant C_TSUCL     : time := G_TSUCL_NS * 1 ns;
  constant C_TSUD      : time := G_TSUD_NS * 1 ns;
  constant C_TDHD      : time := G_TDHD_NS * 1 ns;
  constant C_TCS       : time := G_TCS_NS * 1 ns;
  constant C_TSYNC     : time := G_TSYNC_NS * 1 ns;

begin

  assert G_VA_V > 0.0
    report G_NAME & ": G_VA_V must be positive" severity failure;
  assert C_TH + C_TL <= C_TSCLK_MIN
    report G_NAME & ": tH + tL must not exceed the minimum SCLK period" severity failure;

  p_model : process (sync_n_i, sclk_i, din_i, report_i)
    variable in_frame       : boolean := false;
    variable bitcnt         : natural := 0;
    variable shreg          : std_logic_vector(15 downto 0) := (others => '0');
    variable dac_reg        : std_logic_vector(11 downto 0) := (others => '0');
    variable mode           : std_logic_vector(1 downto 0)  := "00";
    -- timestamps
    variable t_sync_fall    : time := 0 ns;
    variable t_sync_rise    : time := 0 ns;
    variable t_last_fall    : time := 0 ns;
    variable t_last_rise    : time := 0 ns;
    variable t_din_change   : time := 0 ns;
    variable t_last_latch   : time := 0 ns;
    variable sync_rise_seen : boolean := false;
    variable fall_in_frame  : boolean := false;   -- an SCLK falling edge occurred in this frame
    variable rise_in_frame  : boolean := false;   -- an SCLK rising edge occurred in this frame
    variable latch_seen     : boolean := false;
    variable extra_warned   : boolean := false;
    -- statistics
    variable n_frames       : natural := 0;
    variable n_aborted      : natural := 0;
    variable n_err          : natural := 0;
    variable n_warn         : natural := 0;
    -- scratch
    variable per            : time;
    variable c              : natural;
    variable v              : real;

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

  begin

    ----------------------------------------------------------------------------
    -- summary on request
    ----------------------------------------------------------------------------
    if rising_edge(report_i) then
      report G_NAME & " SUMMARY: frames written = " & natural'image(n_frames) &
             ", frames aborted by SYNC = " & natural'image(n_aborted) &
             ", protocol errors = " & natural'image(n_err) &
             ", warnings = " & natural'image(n_warn) &
             ", DAC register = " & hex(dac_reg) & ", mode PD1 PD0 = " & to_string(mode)
        severity note;
    end if;

    ----------------------------------------------------------------------------
    -- DIN change: hold-time check against the last latching edge
    ----------------------------------------------------------------------------
    if din_i'event then
      t_din_change := now;
      if in_frame and latch_seen and (now - t_last_latch) < C_TDHD then
        err("tDHD DIN changed " & fmt_ns(now - t_last_latch) &
            " after the latching SCLK falling edge < " & fmt_ns(C_TDHD) & " min");
      end if;
    end if;

    ----------------------------------------------------------------------------
    -- SYNC falling edge: new write sequence
    ----------------------------------------------------------------------------
    if falling_edge(sync_n_i) then
      if sync_rise_seen and (now - t_sync_rise) < C_TSYNC then
        err("tSYNC SYNC high time " & fmt_ns(now - t_sync_rise) & " < " & fmt_ns(C_TSYNC) & " min");
      end if;
      -- Figure 2: SYNC falls while SCLK is low; tSUCL >= 0 means the first SCLK rising edge
      -- may coincide with, but must not precede, the SYNC falling edge.
      if to_x01(sclk_i) = '1' and not sclk_i'event then
        err("SCLK already high at the SYNC falling edge: the first SCLK rising edge precedes SYNC (tSUCL < " &
            fmt_ns(C_TSUCL) & " min)");
      end if;
      in_frame      := true;
      bitcnt        := 0;
      t_sync_fall   := now;
      fall_in_frame := false;
      rise_in_frame := false;
      latch_seen    := false;
      extra_warned  := false;
      note("SYNC fell: write sequence starts");
    end if;

    ----------------------------------------------------------------------------
    -- SYNC rising edge: frame end or abort
    ----------------------------------------------------------------------------
    if rising_edge(sync_n_i) then
      if in_frame then
        in_frame := false;
        if bitcnt = 0 then
          warn("SYNC pulse without any SCLK falling edge: empty write sequence ignored");
        elsif bitcnt < 16 then
          -- "if SYNC is brought high before the 16th falling edge, the shift register is reset and the write sequence is invalid"
          n_aborted := n_aborted + 1;
          err("SYNC rose after " & natural'image(bitcnt) &
              " of 16 bits: shift register reset, write ignored, DAC register and output unchanged");
        else
          if (now - t_last_latch) < C_TCS then
            err("tCS 16th SCLK falling edge to SYNC rising " & fmt_ns(now - t_last_latch) & " < " &
                fmt_ns(C_TCS) & " min");
          end if;
        end if;
      end if;
      t_sync_rise    := now;
      sync_rise_seen := true;
    end if;

    ----------------------------------------------------------------------------
    -- SCLK rising edge inside the frame: tSUCL (first edge) and tL checks
    ----------------------------------------------------------------------------
    if rising_edge(sclk_i) and in_frame then
      if not rise_in_frame and (now - t_sync_fall) < C_TSUCL then
        err("tSUCL SYNC falling to first SCLK rising edge " & fmt_ns(now - t_sync_fall) & " < " &
            fmt_ns(C_TSUCL) & " min");
      end if;
      if fall_in_frame and (now - t_last_fall) < C_TL then
        err("tL SCLK low time " & fmt_ns(now - t_last_fall) & " < " & fmt_ns(C_TL) & " min");
      end if;
      t_last_rise   := now;
      rise_in_frame := true;
    end if;

    ----------------------------------------------------------------------------
    -- SCLK falling edge inside the frame: latch DIN (MSB first)
    ----------------------------------------------------------------------------
    if falling_edge(sclk_i) and in_frame then
      if rise_in_frame and (now - t_last_rise) < C_TH then
        err("tH SCLK high time " & fmt_ns(now - t_last_rise) & " < " & fmt_ns(C_TH) & " min");
      end if;
      if fall_in_frame then
        per := now - t_last_fall;
        if per < C_TSCLK_MIN then
          err("SCLK period " & fmt_ns(per) & " < " & fmt_ns(C_TSCLK_MIN) & " (fSCLK max " &
              natural'image(G_FSCLK_MAX_HZ / 1_000_000) & " MHz)");
        end if;
      end if;
      if (now - t_din_change) < C_TSUD then
        err("tSUD DIN changed only " & fmt_ns(now - t_din_change) &
            " before the latching SCLK falling edge < " & fmt_ns(C_TSUD) & " min");
      end if;
      t_last_fall   := now;
      fall_in_frame := true;
      rise_in_frame := false;

      if bitcnt < 16 then
        -- "data on the DIN line is clocked into the 16-bit serial input register on the falling edges of SCLK"
        shreg        := shreg(14 downto 0) & to_x01(din_i);
        bitcnt       := bitcnt + 1;
        t_last_latch := now;
        latch_seen   := true;
        if bitcnt = 16 then
          -- "On the 16th falling clock edge, the last data bit is clocked in and the programmed function ... is executed."
          n_frames      := n_frames + 1;
          frame_o       <= shreg;
          frame_valid_o <= '1', '0' after 1 ns;
          if is_x(shreg) then
            err("frame contains metavalues: " & bits_grouped(shreg) & " - DAC register not updated");
          else
            mode    := shreg(13 downto 12);
            dac_reg := shreg(11 downto 0);
            mode_o     <= mode;
            dac_code_o <= dac_reg;
            if mode /= "00" then
              if G_EXPECT_NORMAL then
                err("power-down mode PD1 PD0 = " & to_string(mode) &
                    " received (Table 1); output pulled to GND (Hi-Z modelled as 0 V)");
              else
                note("power-down mode PD1 PD0 = " & to_string(mode) & " received");
              end if;
              c := 0;
              v := 0.0;
            else
              c := to_integer(unsigned(dac_reg));
              v := code_to_volts(c, G_VA_V);
            end if;
            -- zero-order settling: old value until ts, then the new value
            analog_out    <= transport v after C_SETTLE;
            analog_code_o <= transport c after C_SETTLE;
            note("frame " & bits_grouped(shreg) & " = " & hex(shreg) & " -> code " & natural'image(c) &
                 " = " & fmt_real(v, 4) & " V after " & fmt_ns(C_SETTLE));
          end if;
        end if;
      else
        if not extra_warned then
          warn("SCLK falling edge after the 16th bit while SYNC is still low: not part of any write (ignored)");
          extra_warned := true;
        end if;
      end if;
    end if;

    ----------------------------------------------------------------------------
    -- status outputs (also executed once at time 0)
    ----------------------------------------------------------------------------
    frame_count_o <= n_frames;
    error_count_o <= n_err;
    warn_count_o  <= n_warn;
  end process p_model;

end architecture sim;
