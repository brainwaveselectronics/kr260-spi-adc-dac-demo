--------------------------------------------------------------------------------
-- Project: KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
-- @author  Marek Palka
-- @date    2026-10-13
-- @brief   Two status LEDs: led_o(0) blinks at 1 Hz from the fabric clock
--          ("the PL is alive and clocked"), led_o(1) toggles every 2**18
--          sample_valid_i pulses ("the ADC loop is alive": 2**18 / 500 kSPS
--          = 0.52 s per toggle).
-- @details led_o(0) toggles every G_CLK_HZ/2 ticks -> 1 Hz, 50 % duty.
--          led_o(1) is driven by an 18-bit counter of sample_valid_i pulses and
--          toggles on its wrap-around. Both LEDs start low after reset. The KR260
--          user LEDs (F8, E8) blink visibly whichever polarity the carrier uses.
--------------------------------------------------------------------------------
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity heartbeat is
  generic (
    G_CLK_HZ : positive := 100_000_000   -- clk_i frequency in Hz
  );
  port (
    clk_i          : in  std_logic;
    rst_i          : in  std_logic;      -- synchronous, active high
    sample_valid_i : in  std_logic;      -- one pulse per ADC frame
    led_o          : out std_logic_vector(1 downto 0)  -- (0) 1 Hz heartbeat, (1) ADC activity
  );
end entity heartbeat;

architecture rtl of heartbeat is

  constant C_HALF_PERIOD_TICKS : positive := G_CLK_HZ / 2;   -- LED0 toggles every half second
  constant C_SAMPLE_CNT_BITS   : positive := 18;             -- LED1 toggles every 2**18 samples

  signal tick_cnt   : natural range 0 to C_HALF_PERIOD_TICKS - 1;
  signal sample_cnt : unsigned(C_SAMPLE_CNT_BITS - 1 downto 0);
  signal led_r      : std_logic_vector(1 downto 0);

begin

  assert G_CLK_HZ >= 2
    report "heartbeat: G_CLK_HZ must be >= 2 Hz"
    severity failure;

  led_o <= led_r;

  p_main : process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        tick_cnt   <= 0;
        sample_cnt <= (others => '0');
        led_r      <= (others => '0');
      else
        -- LED0: 1 Hz from the fabric clock
        if tick_cnt = C_HALF_PERIOD_TICKS - 1 then
          tick_cnt <= 0;
          led_r(0) <= not led_r(0);
        else
          tick_cnt <= tick_cnt + 1;
        end if;

        -- LED1: toggles every 2**18 ADC frames (counter wrap-around)
        if sample_valid_i = '1' then
          sample_cnt <= sample_cnt + 1;
          if sample_cnt = to_unsigned(2 ** C_SAMPLE_CNT_BITS - 1, C_SAMPLE_CNT_BITS) then
            led_r(1) <= not led_r(1);
          end if;
        end if;
      end if;
    end if;
  end process p_main;

end architecture rtl;
