/******************************************************************************
 * Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
 * @file    spi_demo.c
 * @author  Marek Palka
 * @date    2026-10-13
 * @brief   Bare-metal MicroBlaze program that drives two standard AXI Quad SPI
 *          IP cores: one streams a 1 kHz-class sine to the DAC, the other reads
 *          the ADC continuously. Every ADC sample is mirrored to an AXI GPIO so
 *          the "waveform" ILA can show the reconstructed signal.
 * @details Register-level on purpose (no driver dependency): the whole SPI
 *          "complexity" is five registers of the AXI Quad SPI (PG153):
 *            SRR 0x40  software reset          SPICR 0x60 control (mode, enable)
 *            SPISR 0x64 status (FIFO flags)    SPIDTR 0x68 TX data  SPIDRR 0x6C RX data
 *            SPISSR 0x70 slave select (active low bits)
 *          One 16-bit frame = assert SS, write one word, release the transfer
 *          inhibit, wait until the word came back, read it, deassert SS.
 *
 *          SPI modes (set at run time in SPICR):
 *            ADC AD7476A : CPOL=1, CPHA=0 ("mode 2") — SCLK idles high, the IP
 *                          samples MISO on the FALLING edge. The ADC launches each
 *                          bit on the falling edge (t4 <= 40 ns) and holds it
 *                          >= t7 = 10 ns after the next one, so the master reads
 *                          the bit launched one SCLK period earlier: 16 falling
 *                          edges give  0000 DB11..DB0  (4 leading zeros, MSB first).
 *                          A mode-3 master (sampling on the rising edge) would get
 *                          000 DB11..DB0 X  = result in bits [12:1] — the mistake
 *                          in Digilent's PmodAD1 IP. "Das Datenblatt entscheidet."
 *            DAC DAC121S101: CPOL=0, CPHA=1 ("mode 1") — MOSI changes on the
 *                          rising edge, the DAC latches on the falling edge; frame
 *                          = X X PD1 PD0 D11..D0 = 0000 & code (normal operation).
 *          SCLK = 100 MHz / C_SCK_RATIO(16) = 6.25 MHz (AD7476A max 20 MHz,
 *          DAC121S101 max 30 MHz). CS/SYNC are driven by software between frames
 *          (microseconds), which satisfies t1/t2/tQUIET (AD7476A) and
 *          tSYNC/tCS (DAC121S101) by a wide margin. The AD7476A must never see CS
 *          rise between the 2nd and 10th SCLK falling edge (power-down window):
 *          the IP always clocks the full 16 bits before software deasserts CS.
 *
 *          Addresses are fixed by vivado/scripts/create_bd.tcl (assign_bd_address).
 *          Build: Vitis 2025.2 standalone BSP (xil_io.h) or plain mb-gcc with
 *          -DNO_BSP (volatile pointer accessors, no printing).
 ******************************************************************************/
#include <stdint.h>

#ifdef NO_BSP
#  define REG32(a)            (*(volatile uint32_t *)(uintptr_t)(a))
#  define Xil_Out32(a, v)     (REG32(a) = (uint32_t)(v))
#  define Xil_In32(a)         (REG32(a))
#else
#  include "xil_io.h"
#endif
/* Diagnostic prints go to the MDM JTAG UART. With no terminal attached its TX
 * FIFO fills up and xil_printf BLOCKS FOREVER (found in the xsim closed-loop run:
 * the loop never started). Therefore prints are opt-in: build with
 * -DSPI_DEMO_VERBOSE only for a bring-up session with "xsct -> jtagterminal". */
#if defined(SPI_DEMO_VERBOSE) && !defined(NO_BSP)
#  include "xil_printf.h"
#  define DIAG(...)           xil_printf(__VA_ARGS__)
#else
#  define DIAG(...)           ((void)0)
#endif

/* ---- base addresses (must match create_bd.tcl) ------------------------- */
#define SPI_ADC_BASE   0x44A00000u   /* axi_quad_spi_adc  (Pmod AD1, AD7476A)   */
#define SPI_DAC_BASE   0x44A10000u   /* axi_quad_spi_dac  (Pmod DA2, DAC121S101)*/
#define GPIO_MIRROR    0x40000000u   /* axi_gpio_mirror   32-bit output          */
#define GPIO_LED       0x40010000u   /* axi_gpio_led      bit 0 = LED1           */

/* ---- AXI Quad SPI register map (PG153, standard mode) -------------------- */
#define SPI_DGIER   0x1Cu   /* device global interrupt enable (0 = polled)      */
#define SPI_IPISR   0x20u   /* IP interrupt status (write 1 to clear)           */
#define SPI_SRR     0x40u   /* software reset register: write 0x0000000A        */
#define SPI_CR      0x60u   /* control                                          */
#define SPI_SR      0x64u   /* status                                           */
#define SPI_DTR     0x68u   /* transmit data (N = transfer width bits)          */
#define SPI_DRR     0x6Cu   /* receive data                                     */
#define SPI_SSR     0x70u   /* slave select: bit n low = SS_n asserted          */
#define SPI_TXOCC   0x74u   /* TX FIFO occupancy - 1                            */
#define SPI_RXOCC   0x78u   /* RX FIFO occupancy - 1                            */

#define CR_LOOP          (1u << 0)
#define CR_SPE           (1u << 1)   /* SPI system enable                       */
#define CR_MASTER        (1u << 2)
#define CR_CPOL          (1u << 3)   /* 1 = SCLK idles high                     */
#define CR_CPHA          (1u << 4)   /* 1 = sample on the second (trailing) edge*/
#define CR_TXFIFO_RESET  (1u << 5)
#define CR_RXFIFO_RESET  (1u << 6)
#define CR_MANUAL_SS     (1u << 7)   /* software controls SPISSR                */
#define CR_TRANS_INHIBIT (1u << 8)   /* 1 = master does not start a transfer    */
#define CR_LSB_FIRST     (1u << 9)   /* 0 = MSB first                           */

#define SR_RX_EMPTY      (1u << 0)
#define SR_RX_FULL       (1u << 1)
#define SR_TX_EMPTY      (1u << 2)
#define SR_TX_FULL       (1u << 3)
#define SR_MODF          (1u << 4)

/* mode bits: ADC = CPOL 1 / CPHA 0 ; DAC = CPOL 0 / CPHA 1 */
#define MODE_ADC   (CR_CPOL)
#define MODE_DAC   (CR_CPHA)

/* ---- GPIO (AXI GPIO v2, channel 1) -------------------------------------- */
#define GPIO_DATA   0x0u
#define GPIO_TRI    0x4u             /* 0 = output                              */

/* ---- demo parameters ----------------------------------------------------- */
#define SINE_POINTS      100u        /* DAC updates per sine period             */
#define ADC_PER_DAC      4u          /* ADC frames per DAC update               */
#define LED_DIV_LOG2     14u         /* LED1 toggles every 2^14 DAC updates     */

static const uint16_t sine_table[SINE_POINTS] = {   /* 2048 + 1792*sin, codes 256..3840 */
    2048, 2161, 2273, 2384, 2494, 2602, 2708, 2811, 2911, 3008,
    3101, 3190, 3275, 3354, 3429, 3498, 3561, 3618, 3669, 3714,
    3752, 3784, 3808, 3826, 3836, 3840, 3836, 3826, 3808, 3784,
    3752, 3714, 3669, 3618, 3561, 3498, 3429, 3354, 3275, 3190,
    3101, 3008, 2911, 2811, 2708, 2602, 2494, 2384, 2273, 2161,
    2048, 1935, 1823, 1712, 1602, 1494, 1388, 1285, 1185, 1088,
     995,  906,  821,  742,  667,  598,  535,  478,  427,  382,
     344,  312,  288,  270,  260,  256,  260,  270,  288,  312,
     344,  382,  427,  478,  535,  598,  667,  742,  821,  906,
     995, 1088, 1185, 1285, 1388, 1494, 1602, 1712, 1823, 1935,
};

static inline uint32_t rd32(uint32_t base, uint32_t off) { return Xil_In32(base + off); }
static inline void     wr32(uint32_t base, uint32_t off, uint32_t v) { Xil_Out32(base + off, v); }

/* Approximate wait: each AXI-Lite register read costs on the order of 10-20
 * MicroBlaze cycles at 100 MHz, so 40 reads are roughly 5 us. Used only to let
 * the DAC output settle (DAC121S101: 1 V/us slew; the sine steps are <= 91 mV,
 * i.e. well under 1 us, so 5 us is generous) before the first ADC frame. */
static void settle_wait(void)
{
    for (uint32_t i = 0u; i < 40u; i++) {
        (void)rd32(SPI_DAC_BASE, SPI_SR);
    }
}

/* Reset one AXI Quad SPI core and leave it enabled as master, SS deasserted,
 * transfers inhibited, FIFOs empty, in the requested SPI mode. */
static void spi_init(uint32_t base, uint32_t mode)
{
    wr32(base, SPI_SRR, 0x0000000Au);                       /* core reset           */
    wr32(base, SPI_DGIER, 0u);                              /* polled, no interrupts */
    wr32(base, SPI_CR, CR_MASTER | CR_MANUAL_SS | CR_TRANS_INHIBIT | mode
                      | CR_TXFIFO_RESET | CR_RXFIFO_RESET); /* flush FIFOs          */
    wr32(base, SPI_CR, CR_MASTER | CR_MANUAL_SS | CR_TRANS_INHIBIT | mode | CR_SPE);
    wr32(base, SPI_SSR, 0xFFFFFFFFu);                       /* all SS high          */
}

/* One 16-bit SPI frame: SS low for exactly 16 SCLK cycles. Returns the 16 bits
 * received on MISO (for the DAC core MISO is tied low -> returns 0). */
static uint16_t spi_frame16(uint32_t base, uint32_t mode, uint16_t tx)
{
    const uint32_t cr_run  = CR_MASTER | CR_MANUAL_SS | mode | CR_SPE;
    const uint32_t cr_hold = cr_run | CR_TRANS_INHIBIT;

    wr32(base, SPI_DTR, tx);                /* word waits in the TX FIFO (inhibited) */
    wr32(base, SPI_SSR, 0xFFFFFFFEu);       /* SS0 low  -> CS / SYNC falling edge    */
    wr32(base, SPI_CR, cr_run);             /* release inhibit -> 16 SCLK cycles     */
    while (rd32(base, SPI_SR) & SR_RX_EMPTY) { /* the word arrives in the RX FIFO    */
        ;                                      /* only after the 16th SCLK edge      */
    }
    wr32(base, SPI_CR, cr_hold);            /* inhibit again (frame done)            */
    wr32(base, SPI_SSR, 0xFFFFFFFFu);       /* SS0 high -> CS / SYNC rising edge     */
    return (uint16_t)rd32(base, SPI_DRR);
}

int main(void)
{
    uint32_t idx = 0u, updates = 0u, toggle = 0u, led = 0u;

    wr32(GPIO_MIRROR, GPIO_TRI, 0u);        /* outputs */
    wr32(GPIO_LED,    GPIO_TRI, 0u);
    wr32(GPIO_MIRROR, GPIO_DATA, 0u);
    wr32(GPIO_LED,    GPIO_DATA, 0u);

    spi_init(SPI_DAC_BASE, MODE_DAC);
    spi_init(SPI_ADC_BASE, MODE_ADC);

    DIAG("\r\nKR260 SPI demo: MicroBlaze + 2x AXI Quad SPI, SCLK 6.25 MHz\r\n");

    /* The AD7476A may power up in power-down mode: the first full 16-clock frame
     * wakes it (dummy conversion), the next one is valid (data sheet, Power-Up Time). */
    (void)spi_frame16(SPI_ADC_BASE, MODE_ADC, 0u);
    (void)spi_frame16(SPI_ADC_BASE, MODE_ADC, 0u);

    for (;;) {
        const uint16_t code = sine_table[idx];
        if (++idx == SINE_POINTS) { idx = 0u; }

        /* DAC: X X PD1 PD0 D11..D0 = 0000 & code -> normal operation, new value */
        (void)spi_frame16(SPI_DAC_BASE, MODE_DAC, (uint16_t)(code & 0x0FFFu));
        settle_wait();                       /* let VOUT settle before sampling it */

        /* ADC: several frames per DAC step; each sample goes to the mirror GPIO */
        for (uint32_t k = 0u; k < ADC_PER_DAC; k++) {
            const uint16_t raw = spi_frame16(SPI_ADC_BASE, MODE_ADC, 0u);
            toggle ^= 1u;
            /* [11:0] ADC sample  [23:12] DAC code  [24] valid toggle  [28:25] leading-zero nibble */
            wr32(GPIO_MIRROR, GPIO_DATA,
                 (uint32_t)(raw & 0x0FFFu) | ((uint32_t)(code & 0x0FFFu) << 12)
                 | (toggle << 24) | (((uint32_t)raw >> 12) << 25));
            if (updates < 4u && k == 0u) {
                DIAG("DAC 0x%03x -> ADC raw 0x%04x (zeros 0x%x, sample %d)\r\n",
                     code, raw, raw >> 12, raw & 0x0FFFu);
            }
        }

        if ((++updates & ((1u << LED_DIV_LOG2) - 1u)) == 0u) {   /* "loop alive" */
            led ^= 1u;
            wr32(GPIO_LED, GPIO_DATA, led);
        }
    }
    return 0;
}
