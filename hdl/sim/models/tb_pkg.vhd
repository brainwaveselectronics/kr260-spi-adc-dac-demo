--------------------------------------------------------------------------------
-- Project: KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
-- @author  Marek Palka
-- @date    2026-10-13
-- @brief   Helper package shared by the behavioural models and the testbenches.
-- @details Contains
--            * the one code <-> volts conversion used by BOTH models (so a DAC code
--              survives the analog "jumper" into the ADC model bit-exactly;
--              AD7476A: straight binary, LSB = VDD/4096 (data sheet p.15);
--              DAC121S101: VOUT = VA x D/4096 (SNAS265J 8.3.1)),
--            * string formatting helpers for readable reports,
--            * a protected counter for testbench check failures.
--          Simulation only (uses ieee.math_real at run time) - never synthesise.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package tb_pkg is

  -- Straight-binary conversion, code transitions at integer LSB values
  -- (AD7476A Figure 17: code = floor(VIN / LSB), clamped to 0..4095).
  -- The tiny epsilon absorbs floating-point rounding so that
  -- volts_to_code(code_to_volts(c)) = c for every c.
  function volts_to_code(v : real; vref : real) return natural;
  function code_to_volts(code : natural; vref : real) return real;

  -- "1600.000 ns" style formatting of a time (ps resolution, sign kept)
  function fmt_ns(t : time) return string;
  -- fixed-point formatting of a real, e.g. fmt_real(3.3, 3) = "3.300"
  function fmt_real(x : real; decimals : natural) return string;
  -- "0x0801"
  function hex(v : std_logic_vector) return string;
  -- "0000 1000 0000 0001" (MSB first, nibble groups)
  function bits_grouped(v : std_logic_vector) return string;

  -- Shared failure counter for the testbench check procedures.
  type t_counter is protected
    procedure inc;
    impure function get return natural;
  end protected t_counter;

end package tb_pkg;

package body tb_pkg is

  function volts_to_code(v : real; vref : real) return natural is
    variable lsb : real;
    variable q   : real;
  begin
    lsb := vref / 4096.0;
    q   := floor(v / lsb + 1.0e-9);
    if q < 0.0 then
      return 0;
    elsif q > 4095.0 then
      return 4095;
    else
      return natural(q);
    end if;
  end function;

  function code_to_volts(code : natural; vref : real) return real is
  begin
    return vref * real(code) / 4096.0;
  end function;

  function fmt_ns(t : time) return string is
    variable a       : time;
    variable ns_part : integer;
    variable ps_part : integer;
    variable frac    : string(1 to 3);
  begin
    if t < 0 ns then
      a := -t;
    else
      a := t;
    end if;
    ns_part := a / 1 ns;
    ps_part := (a - ns_part * 1 ns) / 1 ps;
    frac(1) := character'val(character'pos('0') + (ps_part / 100) mod 10);
    frac(2) := character'val(character'pos('0') + (ps_part / 10) mod 10);
    frac(3) := character'val(character'pos('0') + ps_part mod 10);
    if t < 0 ns then
      return "-" & integer'image(ns_part) & "." & frac & " ns";
    else
      return integer'image(ns_part) & "." & frac & " ns";
    end if;
  end function;

  function fmt_real(x : real; decimals : natural) return string is
    variable scale : real;
    variable ax    : real;
    variable ip    : integer;
    variable fp    : integer;
    variable fs    : string(1 to decimals);
    variable d     : integer;
  begin
    scale := 10.0 ** decimals;
    ax    := abs(x);
    ip    := integer(floor(ax));
    fp    := integer(round((ax - real(ip)) * scale));
    if fp >= integer(scale) then
      ip := ip + 1;
      fp := fp - integer(scale);
    end if;
    d := fp;
    for i in decimals downto 1 loop
      fs(i) := character'val(character'pos('0') + d mod 10);
      d     := d / 10;
    end loop;
    if decimals = 0 then
      if x < 0.0 then
        return "-" & integer'image(ip);
      end if;
      return integer'image(ip);
    end if;
    if x < 0.0 then
      return "-" & integer'image(ip) & "." & fs;
    end if;
    return integer'image(ip) & "." & fs;
  end function;

  function hex(v : std_logic_vector) return string is
  begin
    return "0x" & to_hstring(v);
  end function;

  function bits_grouped(v : std_logic_vector) return string is
    alias a : std_logic_vector(v'length - 1 downto 0) is v;
    variable s : string(1 to v'length + (v'length - 1) / 4);
    variable p : positive := 1;
    variable n : natural  := 0;
  begin
    for k in a'high downto 0 loop
      s(p) := std_logic'image(a(k))(2);
      p    := p + 1;
      n    := n + 1;
      if (n mod 4 = 0) and k /= 0 then
        s(p) := ' ';
        p    := p + 1;
      end if;
    end loop;
    return s;
  end function;

  type t_counter is protected body
    variable cnt : natural := 0;
    procedure inc is
    begin
      cnt := cnt + 1;
    end procedure;
    impure function get return natural is
    begin
      return cnt;
    end function;
  end protected body t_counter;

end package body tb_pkg;
