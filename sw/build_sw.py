#!/usr/bin/env python3
"""
Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
@author  Marek Palka
@date    2026-10-13
@brief   Builds spi_demo.elf for the MicroBlaze with the Vitis 2025.2 unified
         Python CLI:   source /opt/Xilinx/2025.2/2025.2/Vitis/settings64.sh
                       vitis -s build_sw.py [--xsa <file>] [--clean]
@details Steps: platform component from the Vivado .xsa (standalone domain on
         microblaze_0, stdin/stdout = MDM JTAG UART when the BSP accepts it)
         -> app component from the "empty_application" template -> import
         spi_demo.c -> build -> copy the ELF to sw/output/spi_demo.elf.
         Workspace: sw/build/vitis_ws (gitignored). Exit code 1 on any failure.
         Fallback if this flow misbehaves: sw/build_sw_xsct.tcl (xsct).
"""
import os, sys, shutil, glob, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
XSA = os.path.join(HERE, "..", "vivado", "output", "kr260_spi_demo.xsa")
WS = os.path.join(HERE, "build", "vitis_ws")
OUT = os.path.join(HERE, "output")
PLATFORM = "kr260_mb_platform"
DOMAIN = "standalone_microblaze_0"
APP = "spi_demo"

args = sys.argv[1:]
if "--xsa" in args:
    XSA = args[args.index("--xsa") + 1]
XSA = os.path.abspath(XSA)
if not os.path.isfile(XSA):
    print(f"[build_sw] ERROR: XSA not found: {XSA}")
    sys.exit(1)
if "--clean" in args and os.path.isdir(WS):
    shutil.rmtree(WS)
os.makedirs(WS, exist_ok=True)
os.makedirs(OUT, exist_ok=True)

import vitis  # provided by the Vitis python environment (vitis -s)

client = vitis.create_client()
try:
    client.set_workspace(WS)
    print(f"[build_sw] workspace {WS}\n[build_sw] XSA {XSA}")

    # ---- platform (standalone BSP for microblaze_0) ----------------------
    existing = [c for c in (client.list_components() or []) if PLATFORM in str(c)] if hasattr(client, "list_components") else []
    if existing:
        print(f"[build_sw] platform {PLATFORM} exists - reusing (use --clean to rebuild)")
        platform = client.get_component(name=PLATFORM)
    else:
        platform = client.create_platform_component(name=PLATFORM, hw_design=XSA,
                                                    os="standalone", cpu="microblaze_0",
                                                    domain_name=DOMAIN)
        # stdout/stdin to the MDM JTAG UART (best effort - names differ between BSP flavours)
        try:
            dom = platform.get_domain(name=DOMAIN)
            for param in ("standalone_stdin", "standalone_stdout"):
                try:
                    dom.set_config(option="os", param=param, value="mdm_1")
                except Exception as e:  # noqa: BLE001
                    print(f"[build_sw] note: could not set {param}=mdm_1 ({e})")
        except Exception as e:  # noqa: BLE001
            print(f"[build_sw] note: domain config skipped ({e})")
    platform.build()
    xpfm = client.find_platform_in_repos(PLATFORM)
    print(f"[build_sw] platform built: {xpfm}")

    # ---- application --------------------------------------------------
    try:
        app = client.get_component(name=APP)
        print(f"[build_sw] app {APP} exists - reusing sources from {HERE}")
    except Exception:  # noqa: BLE001
        app = client.create_app_component(name=APP, platform=xpfm, domain=DOMAIN,
                                          template="empty_application")
    app.import_files(from_loc=HERE, files=["spi_demo.c"], dest_dir_in_cmp="src")
    # Optimisation: the Vitis default is -O0 (loop ~48 us per DAC update in xsim); -O2 roughly halves the overhead.
    for key, val in (("USER_COMPILE_OPTIMIZATION_LEVEL", "-O2"), ("USER_COMPILE_DEBUG_LEVEL", "-g0")):
        try:
            app.set_app_config(key=key, values=val)
            print(f"[build_sw] app config {key} = {val}")
        except Exception as e:  # noqa: BLE001
            print(f"[build_sw] note: could not set {key} ({e})")
    app.build()

    elfs = glob.glob(os.path.join(WS, APP, "build", "**", f"{APP}.elf"), recursive=True) + \
           glob.glob(os.path.join(WS, APP, "**", f"{APP}.elf"), recursive=True)
    if not elfs:
        print("[build_sw] ERROR: no ELF produced; look into", os.path.join(WS, APP))
        sys.exit(1)
    elf = sorted(elfs, key=os.path.getmtime)[-1]
    dst = os.path.join(OUT, f"{APP}.elf")
    shutil.copyfile(elf, dst)
    print(f"[build_sw] ELF: {elf}\n[build_sw] copied to {dst} ({os.path.getsize(dst)} bytes)")
    print("[build_sw] DONE")
except SystemExit:
    raise
except Exception:  # noqa: BLE001
    traceback.print_exc()
    print("[build_sw] FAILED")
    sys.exit(1)
finally:
    try:
        vitis.dispose()
    except Exception:  # noqa: BLE001
        pass
