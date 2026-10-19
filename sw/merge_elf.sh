#!/usr/bin/env bash
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @brief   Merges spi_demo.elf into the bitstream's MicroBlaze BRAM (updatemem)
#          -> vivado/output/kr260_spi_demo_sw.bit = the file to program on stage.
# @details Needs the .mmi written by build.tcl (write_mem_info) next to the .bit.
#          Usage: ./merge_elf.sh [bit] [mmi] [elf] [out]   (defaults below)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$HERE/../vivado/output"
BIT="${1:-$OUTDIR/kr260_spi_demo.bit}"
MMI="${2:-$OUTDIR/kr260_spi_demo.mmi}"
ELF="${3:-$HERE/output/spi_demo.elf}"
OUT="${4:-$OUTDIR/kr260_spi_demo_sw.bit}"
PROC="${PROC:-spi_demo_bd_i/microblaze_0}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/opt/Xilinx/2025.2/2025.2/Vivado/settings64.sh}"
command -v updatemem >/dev/null 2>&1 || { [ -f "$VIVADO_SETTINGS" ] && source "$VIVADO_SETTINGS"; }
for f in "$BIT" "$MMI" "$ELF"; do [ -f "$f" ] || { echo "merge_elf: missing $f" >&2; exit 2; }; done
echo "merge_elf: updatemem -meminfo $MMI -data $ELF -bit $BIT -proc $PROC -out $OUT"
updatemem -force -meminfo "$MMI" -data "$ELF" -bit "$BIT" -proc "$PROC" -out "$OUT"
ls -la "$OUT"
echo "merge_elf: DONE -> $OUT"
