#!/usr/bin/env python3
"""
Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
@author  Marek Palka
@date    2026-10-17
@brief   Decodes the two ILA captures written by hw_demo.tcl (demo_save_csv) and
         checks them against the datasheets: AD7476A frames (CS low, 16 SCLK falling
         edges, 4 leading zeros, DB11 first), DAC121S101 frames (SYNC low, 16 falling
         edges, 0000 then D11..D0) and the DAC -> ADC loop seen by the software
         (ila_wave: adc_sample vs dac_code). Prints a report and writes two PNGs.
@usage   analyze_ila_csv.py <ila_spi_*.csv> <ila_wave_*.csv> [--png-dir DIR]
         Exit code 0 = all checks passed, 1 = a check failed.
"""
import csv, sys, os, statistics as st

T_SAMPLE_NS = 10.0          # ILA clock = 100 MHz system clock
SCLK_PERIOD_EXPECT = 16     # C_SCK_RATIO 16 -> 160 ns -> 6.25 MHz
SINE_POINTS = 100           # entries of the sine table in sw/spi_demo.c

def load(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    head, data = rows[0], rows[2:]          # row 1 = radix line
    return head, data

def col(head, needle):
    for i, h in enumerate(head):
        if needle in h:
            return i
    raise KeyError(needle)

def bits(data, i):
    return [int(r[i], 16) for r in data]

def falling(sig):
    return [k for k in range(1, len(sig)) if sig[k-1] == 1 and sig[k] == 0]

def rising(sig):
    return [k for k in range(1, len(sig)) if sig[k-1] == 0 and sig[k] == 1]

def frames(cs, sclk, din):
    """One dict per CS/SYNC-low window: start, end, sclk falling edges, bits sampled at them."""
    out = []
    starts = falling(cs)
    for s in starts:
        e = s
        while e < len(cs) and cs[e] == 0:
            e += 1
        if e >= len(cs):
            break                            # frame cut by the capture window
        f = [k for k in falling(sclk) if s <= k < e]
        out.append(dict(start=s, end=e, edges=f, bits=[din[k] for k in f]))
    return out

def word(b):
    v = 0
    for x in b:
        v = (v << 1) | x
    return v

def analyze_spi(path, png_dir):
    head, data = load(path)
    ok = True
    sig = {}
    for key, probe in dict(cs_n="ila_spi/U0/probe0", sclk="ila_spi/U0/probe1", miso="ila_spi/U0/probe2",
                           d1="ila_spi/U0/probe3", sync_n="ila_spi/U0/probe4", dsclk="ila_spi/U0/probe5",
                           din="ila_spi/U0/probe6").items():
        sig[key] = bits(data, col(head, probe))
    n = len(data)
    print(f"== ila_spi: {n} samples x {T_SAMPLE_NS:.0f} ns = {n*T_SAMPLE_NS/1000:.1f} us")

    # ---- ADC frames ---------------------------------------------------------
    adc = frames(sig["cs_n"], sig["sclk"], sig["miso"])
    print(f"ADC frames (CS low windows, complete): {len(adc)}")
    for k, fr in enumerate(adc):
        per = [b - a for a, b in zip(fr["edges"], fr["edges"][1:])]
        w = word(fr["bits"])
        zeros = 0
        for b in fr["bits"]:
            if b: break
            zeros += 1
        first = fr["edges"][0] - fr["start"] if fr["edges"] else -1
        last = fr["end"] - fr["edges"][-1] if fr["edges"] else -1
        cs_low = fr["end"] - fr["start"]
        bitstr = "".join(str(b) for b in fr["bits"])
        print(f"  #{k}: t={fr['start']*T_SAMPLE_NS/1000:7.2f} us  CS low {cs_low*T_SAMPLE_NS:6.0f} ns  "
              f"SCLK falling edges {len(fr['edges'])}  period {min(per) if per else 0}-{max(per) if per else 0} clk  "
              f"CS->1st edge {first*T_SAMPLE_NS:.0f} ns  last edge->CS high {last*T_SAMPLE_NS:.0f} ns")
        print(f"       bits {bitstr[:4]} {bitstr[4:]}  leading zeros {zeros}  sample {w & 0xFFF} (raw 0x{w:04X})")
        if len(fr["edges"]) != 16: ok = False; print("       FAIL: expected 16 SCLK falling edges")
        if per and (min(per) != SCLK_PERIOD_EXPECT or max(per) != SCLK_PERIOD_EXPECT):
            ok = False; print(f"       FAIL: SCLK period not {SCLK_PERIOD_EXPECT} clk")
        if zeros < 4: ok = False; print("       FAIL: fewer than 4 leading zeros")
    if len(adc) >= 2:
        gaps = [b["start"] - a["start"] for a, b in zip(adc, adc[1:])]
        print(f"  CS falling-edge spacing: {min(gaps)*T_SAMPLE_NS/1000:.2f} .. {max(gaps)*T_SAMPLE_NS/1000:.2f} us")
    d1_act = sum(1 for a, b in zip(sig["d1"], sig["d1"][1:]) if a != b)
    print(f"  D1 (second channel, unused): {d1_act} transitions in the window")

    # ---- DAC frames ---------------------------------------------------------
    dac = frames(sig["sync_n"], sig["dsclk"], sig["din"])
    print(f"DAC frames (SYNC low windows, complete): {len(dac)}")
    dac_codes = []
    for k, fr in enumerate(dac):
        per = [b - a for a, b in zip(fr["edges"], fr["edges"][1:])]
        w = word(fr["bits"])
        bitstr = "".join(str(b) for b in fr["bits"])
        dac_codes.append(w & 0xFFF)
        print(f"  #{k}: t={fr['start']*T_SAMPLE_NS/1000:7.2f} us  SYNC low {(fr['end']-fr['start'])*T_SAMPLE_NS:6.0f} ns  "
              f"falling edges {len(fr['edges'])}  period {min(per) if per else 0}-{max(per) if per else 0} clk")
        print(f"       bits {bitstr[:2]} {bitstr[2:4]} {bitstr[4:]}  PD={bitstr[2:4]}  code {w & 0xFFF} (raw 0x{w:04X})")
        if len(fr["edges"]) != 16: ok = False; print("       FAIL: expected 16 SCLK falling edges")
        if (w >> 12) != 0: ok = False; print("       FAIL: control bits not 0000 (normal operation)")
        # DAC data must be stable around the falling edge: check DIN one sample before and after
        for e in fr["edges"]:
            if sig["din"][e-1] != sig["din"][e] or sig["din"][e] != sig["din"][e+1]:
                ok = False; print(f"       FAIL: DIN changes within 10 ns of a falling edge at sample {e}")
                break

    # ---- sequence DAC write -> ADC reads -------------------------------------
    ev = sorted([(fr["start"], "DAC", word(fr["bits"]) & 0xFFF) for fr in dac] +
                [(fr["start"], "ADC", word(fr["bits"]) & 0xFFF) for fr in adc])
    print("Sequence in the window:")
    last_dac = None
    for t, kind, v in ev:
        note = ""
        if kind == "DAC":
            last_dac = v
        elif last_dac is not None:
            note = f"  (DAC code {last_dac}, diff {v - last_dac:+d})"
        print(f"  {t*T_SAMPLE_NS/1000:7.2f} us  {kind} {v:4d}{note}")

    # ---- plot --------------------------------------------------------------
    try:
        import matplotlib; matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        if adc:
            fr = adc[0]
            a, b = max(fr["start"] - 30, 0), min(fr["end"] + 30, n)
            t = [k * T_SAMPLE_NS for k in range(a, b)]
            fig, axs = plt.subplots(3, 1, sharex=True, figsize=(10, 4.2))
            for ax, key, lab in zip(axs, ["cs_n", "sclk", "miso"], ["CS", "SCLK", "SDATA (D0)"]):
                ax.step(t, sig[key][a:b], where="post", lw=1.4)
                ax.set_ylabel(lab, rotation=0, ha="right", va="center"); ax.set_yticks([0, 1]); ax.set_ylim(-0.3, 1.3)
                ax.grid(alpha=0.3)
            for i, e in enumerate(fr["edges"]):
                axs[2].annotate(str(fr["bits"][i]), (e * T_SAMPLE_NS, 1.15), ha="center", fontsize=8,
                                color="C3" if i < 4 else "C0")
            axs[0].set_title(f"AD7476A frame (ILA, 10 ns/sample): sample = {word(fr['bits']) & 0xFFF}")
            axs[2].set_xlabel("t / ns")
            fig.tight_layout(); fig.savefig(os.path.join(png_dir, "ila_spi_adc_frame.png"), dpi=130); plt.close(fig)
        if dac:
            fr = dac[0]
            a, b = max(fr["start"] - 30, 0), min(fr["end"] + 30, n)
            t = [k * T_SAMPLE_NS for k in range(a, b)]
            fig, axs = plt.subplots(3, 1, sharex=True, figsize=(10, 4.2))
            for ax, key, lab in zip(axs, ["sync_n", "dsclk", "din"], ["SYNC", "SCLK", "DIN"]):
                ax.step(t, sig[key][a:b], where="post", lw=1.4)
                ax.set_ylabel(lab, rotation=0, ha="right", va="center"); ax.set_yticks([0, 1]); ax.set_ylim(-0.3, 1.3)
                ax.grid(alpha=0.3)
            for i, e in enumerate(fr["edges"]):
                axs[2].annotate(str(fr["bits"][i]), (e * T_SAMPLE_NS, 1.15), ha="center", fontsize=8,
                                color="C3" if i < 4 else "C0")
            axs[0].set_title(f"DAC121S101 frame (ILA, 10 ns/sample): code = {word(fr['bits']) & 0xFFF}")
            axs[2].set_xlabel("t / ns")
            fig.tight_layout(); fig.savefig(os.path.join(png_dir, "ila_spi_dac_frame.png"), dpi=130); plt.close(fig)
    except Exception as e:  # plotting is optional
        print(f"  (no plot: {e})")
    return ok, adc, dac

def analyze_wave(path, png_dir):
    head, data = load(path)
    ok = True
    smp = [int(r[col(head, "ila_wave/U0/probe0")]) for r in data]
    code = [int(r[col(head, "ila_wave/U0/probe1")]) for r in data]
    valid = [int(r[col(head, "ila_wave/U0/probe2")], 16) for r in data]
    zeros = [int(r[col(head, "ila_wave/U0/probe3")]) for r in data]
    n = len(data)
    print(f"== ila_wave: {n} rows (one per ADC conversion, capture control on adc_valid)")
    tog = sum(1 for a, b in zip(valid, valid[1:]) if a != b)
    print(f"  adc_valid toggles between consecutive rows: {tog}/{n-1}")
    if tog != n - 1: ok = False; print("  FAIL: capture control did not store exactly one row per conversion")
    nz = sum(1 for z in zeros if z != 0)
    print(f"  adc_zeros (leading nibble) nonzero rows: {nz}/{n}")
    if nz: ok = False; print("  FAIL: leading zeros missing in some conversions")
    # DAC code run lengths (4 ADC reads per DAC update expected)
    runs, r = [], 1
    for a, b in zip(code, code[1:]):
        if a == b: r += 1
        else: runs.append(r); r = 1
    runs.append(r)
    inner = runs[1:-1]
    print(f"  rows per DAC update: {min(inner) if inner else '-'}..{max(inner) if inner else '-'} (expected 4), updates in capture: {len(runs)}")
    print(f"  dac_code range {min(code)}..{max(code)}, adc_sample range {min(smp)}..{max(smp)}")
    # sine period from the DAC code: count upward crossings of the mid code
    mid = (min(code) + max(code)) / 2
    ups = [k for k in range(1, n) if code[k-1] < mid <= code[k]]
    if len(ups) >= 2:
        per_rows = [b - a for a, b in zip(ups, ups[1:])]
        print(f"  sine period: {st.mean(per_rows):.1f} rows = {st.mean(per_rows)/4:.1f} DAC updates (table has {SINE_POINTS} points)")
    # loop error, by position after the DAC write
    diffs = [s - c for s, c in zip(smp, code)]
    print(f"  adc_sample - dac_code (all rows): mean {st.mean(diffs):+.2f} LSB, std {st.pstdev(diffs):.2f}, "
          f"min {min(diffs):+d}, max {max(diffs):+d}")
    pos = {}
    k = 0
    for i in range(n):
        if i > 0 and code[i] != code[i-1]: k = 0
        else: k += 1 if i > 0 else 0
        pos.setdefault(k, []).append(diffs[i])
    for k in sorted(pos)[:4]:
        d = pos[k]
        print(f"    read {k+1} after the DAC write: mean {st.mean(d):+.2f} LSB, std {st.pstdev(d):.2f}, n={len(d)}")
    if abs(st.mean(diffs)) > 40 or st.pstdev(diffs) > 40:
        ok = False; print("  FAIL: ADC does not follow the DAC (loop jumper DA2 VOUTA -> AD1 A0 missing?)")
    try:
        import matplotlib; matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        m = min(n, 1000)
        fig, axs = plt.subplots(2, 1, sharex=True, figsize=(10, 4.6), gridspec_kw=dict(height_ratios=[3, 1]))
        axs[0].plot(range(m), code[:m], lw=1, label="dac_code (written)")
        axs[0].plot(range(m), smp[:m], lw=1, label="adc_sample (read back)", alpha=0.8)
        axs[0].set_ylabel("code / LSB"); axs[0].legend(loc="upper right"); axs[0].grid(alpha=0.3)
        axs[0].set_title("DAC121S101 -> Pmod wire -> AD7476A, one row per conversion")
        axs[1].plot(range(m), diffs[:m], lw=0.8, color="C3"); axs[1].set_ylabel("error / LSB"); axs[1].grid(alpha=0.3)
        axs[1].set_xlabel("conversion index")
        fig.tight_layout(); fig.savefig(os.path.join(png_dir, "ila_wave_loop.png"), dpi=130); plt.close(fig)
    except Exception as e:
        print(f"  (no plot: {e})")
    return ok

def main(argv):
    if len(argv) < 3:
        print(__doc__); return 2
    png_dir = "."
    if "--png-dir" in argv:
        png_dir = argv[argv.index("--png-dir") + 1]
    os.makedirs(png_dir, exist_ok=True)
    ok1, _, _ = analyze_spi(argv[1], png_dir)
    ok2 = analyze_wave(argv[2], png_dir)
    print("RESULT:", "PASS" if ok1 and ok2 else "FAIL")
    return 0 if ok1 and ok2 else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv))
