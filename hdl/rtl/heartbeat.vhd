--! @responsible  Marek Palka
--! @brief        Two status LEDs: a 1 Hz heartbeat from the fabric clock and an activity LED driven by sample pulses.
--! @details      led_o(0) toggles every G_CLK_HZ/2 clock ticks, so it blinks at 1 Hz with 50 % duty and shows that the
--!               bitstream is loaded and the clock runs. led_o(1) toggles on the wrap-around of an 18-bit counter of
--!               sample_valid_i pulses, so it blinks while the ADC loop runs. Both LEDs start low after reset.
--! @copyright    Marek Palka, 2026. MIT License, see the LICENSE file of the repository.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity heartbeat is
  generic (
    G_CLK_HZ : positive := 100_000_000  --! clk_i frequency in Hz
  );
  port (
    -- Clock and reset
    clk_i          : in  std_logic;                     --! fabric clock, frequency set by G_CLK_HZ
    rst_i          : in  std_logic;                     --! synchronous, active-high reset

    -- Activity input
    sample_valid_i : in  std_logic;                     --! one pulse per ADC sample

    -- LEDs
    led_o          : out std_logic_vector(1 downto 0)   --! (0) 1 Hz heartbeat, (1) ADC activity
  );
end entity heartbeat;

architecture rtl of heartbeat is

  ---------------------------------------------------------------------------
  -- Constants
  ---------------------------------------------------------------------------
  constant C_HALF_PERIOD_TICKS : positive := G_CLK_HZ / 2;  -- LED 0 toggles every half second
  constant C_SAMPLE_COUNT_BITS : positive := 18;            -- LED 1 toggles every 2**18 samples

  ---------------------------------------------------------------------------
  -- Signals
  ---------------------------------------------------------------------------
  -- Heartbeat: free-running tick counter and the half-second pulse it produces
  signal tick_count        : natural range 0 to C_HALF_PERIOD_TICKS - 1;
  signal tick_count_next   : natural range 0 to C_HALF_PERIOD_TICKS - 1;
  signal half_second_pulse : std_logic;
  signal heartbeat_led     : std_logic;

  -- Activity: counter of sample pulses and the wrap-around pulse it produces
  signal sample_count      : unsigned(C_SAMPLE_COUNT_BITS - 1 downto 0);
  signal sample_wrap_pulse : std_logic;
  signal activity_led      : std_logic;

begin

  -- Elaboration-time sanity check on the generic
  assert G_CLK_HZ >= 2 report "heartbeat: G_CLK_HZ must be at least 2 Hz" severity failure;

  led_o <= activity_led & heartbeat_led;

  ---------------------------------------------------------------------------
  -- Heartbeat LED, 1 Hz from the fabric clock
  ---------------------------------------------------------------------------
  tick_count_next   <= 0   when tick_count = C_HALF_PERIOD_TICKS - 1 else tick_count + 1;
  half_second_pulse <= '1' when tick_count = C_HALF_PERIOD_TICKS - 1 else '0';

  --! @brief Free-running tick counter, wraps every half second.
  tick_counter : process (clk_i) is
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        tick_count <= 0;
      else
        tick_count <= tick_count_next;
      end if;
    end if;
  end process tick_counter;

  --! @brief Toggles the heartbeat LED on every half-second pulse.
  heartbeat_led_register : process (clk_i) is
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        heartbeat_led <= '0';
      else
        if half_second_pulse = '1' then
          heartbeat_led <= not heartbeat_led;
        else
          heartbeat_led <= heartbeat_led;
        end if;
      end if;
    end if;
  end process heartbeat_led_register;

  ---------------------------------------------------------------------------
  -- Activity LED, toggles every 2**18 sample pulses
  ---------------------------------------------------------------------------
  sample_wrap_pulse <= '1' when sample_valid_i = '1' and sample_count = (sample_count'range => '1') else '0';

  --! @brief Counts sample_valid_i pulses, wraps after 2**18 pulses.
  sample_counter : process (clk_i) is
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        sample_count <= (others => '0');
      else
        if sample_valid_i = '1' then
          sample_count <= sample_count + 1;
        else
          sample_count <= sample_count;
        end if;
      end if;
    end if;
  end process sample_counter;

  --! @brief Toggles the activity LED when the sample counter wraps around.
  activity_led_register : process (clk_i) is
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        activity_led <= '0';
      else
        if sample_wrap_pulse = '1' then
          activity_led <= not activity_led;
        else
          activity_led <= activity_led;
        end if;
      end if;
    end if;
  end process activity_led_register;

end architecture rtl;
