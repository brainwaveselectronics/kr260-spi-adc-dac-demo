################################################################################
# Project : KR260 SPI demo: Pmod AD1 (AD7476A) + Pmod DA2 (DAC121S101)
# @author  Marek Palka
# @date    2026-10-13
# @brief   Hardware Manager procs for the live demo: demo_connect, demo_setup,
#          demo_arm (the ONE click), demo_arm_wave (the encore), demo_save_csv,
#          demo_status, demo_help.
# @details Source it in the Vivado GUI (Hardware Manager Tcl console):
#              source {/<abs path>/kr260_spi_adc_dac_demo/vivado/scripts/hw_demo.tcl}
#          or start Vivado with it:  vivado -mode gui -source hw_demo.tcl -tclargs -autoconnect
#          (-autoconnect runs demo_connect + demo_setup at once; without it only the procs are defined)
#          Then once per session:    demo_connect ; demo_setup
#          On stage:                 demo_arm          (one click / one command: ila_spi)
#          Encore (+1 click):        demo_arm_wave     (ila_wave, re-armed on every click)
#
#          One-click toolbar button (Vivado >= 2019.1):
#            Tools > Custom Commands > Customize Commands... > "+" (new command)
#              Name:    DEMO
#              Tcl:     source {/<abs path>/vivado/scripts/hw_demo.tcl}; demo_arm
#              tick "Add to toolbar" (optionally choose an icon) > OK.
#            Second button "ENCORE" with:  source {...hw_demo.tcl}; demo_arm_wave
#          Loading the procs in every Vivado session instead (UG894):
#            ~/.Xilinx/Vivado/Vivado_init.tcl :  source {/<abs path>/vivado/scripts/hw_demo.tcl}
#
#          Waveform configuration (.wcfg) per ILA: arrange the waveform window
#          once on the bench (dbg_adc_sample as Analog, radix Unsigned, zoom),
#          then File > Save Waveform Configuration As... into
#          vivado/wcfg/ila_spi.wcfg resp. vivado/wcfg/ila_wave.wcfg. demo_arm
#          passes them to display_hw_ila_data -wcfg when they exist, so the
#          analog style and zoom come back with every click.
#
#          This file never calls exit (it is sourced in the GUI); errors are
#          raised with "error" and show up in the Tcl console. Property names
#          follow UG908 ("Using Tcl to configure the ILA"); each set_property is
#          wrapped so a renamed property cannot abort the demo - demo_status
#          prints the real property lists for the bench check (15/16 Oct).
#          ILA plan: README.md, section "The ILA views".
################################################################################
set demo_sourced_by "hw_demo.tcl"
source [file join [file dirname [info script]] settings.tcl]
# In the GUI ::argv may be empty or hold unrelated items; only parse flag-like args.
if {[info exists ::argv] && [string match "-*" [lindex $::argv 0]]} { demo_parse_args $::argv }
demo_resolve_paths

# Probe names = net names in hdl/rtl/kr260_top.vhd (KEEP attribute preserves them).
# Probe names = the buses the System ILA probes are connected to (pin nets carry the
# external port names adc_cs_n_o, adc_sclk_o, adc_d0_i, ...; internal nets adc_sample,
# dac_code, adc_valid, adc_zeros - see vivado/output/kr260_spi_demo.ltx). write_debug_probes may
# prefix them with the hierarchy (spi_demo_bd_i/...) or append [0]/_n suffixes;
# demo_probe_obj matches "<name>", "*/<name>", "<name>_<n>" and "<name>[0]".
set ::demo_probe(cs_n)         adc_cs_n_o
set ::demo_probe(sclk)         adc_sclk_o
set ::demo_probe(miso)         adc_d0_i
set ::demo_probe(d1)           adc_d1_i
set ::demo_probe(dac_sync_n)   dac_sync_n_o
set ::demo_probe(dac_sclk)     dac_sclk_o
set ::demo_probe(dac_din)      dac_dinb_o   ;# the probe sits on the dinb branch of the MOSI net
# waveform ILA (software view via the mirror GPIO)
set ::demo_probe(wav_sample)       adc_sample
set ::demo_probe(wav_sample_valid) adc_valid
set ::demo_probe(wav_dac_code)     dac_code
set ::demo_probe(wav_zeros)        adc_zeros

set ::demo_trigger_position_spi 256     ;# CS falling edge near the left edge of 4096 samples
set ::demo_wait_timeout_min     0.2     ;# wait_on_hw_ila timeout in minutes (= 12 s)
set ::demo_setup_done           0

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
proc demo_try {what script} {
    # Runs a configuration step; a failure is reported, not fatal.
    if {[catch {uplevel 1 $script} msg]} {
        demo_msg WARNING "$what failed: $msg"
        return 0
    }
    return 1
}

proc demo_set {what prop value obj} {
    # set_property only when the value differs: in Vivado 2025.2 CONTROL.CAPTURE_MODE and
    # CONTROL.TRIGGER_MODE are read-only on cores that have no other choice (set would error).
    set cur ""
    catch { set cur [get_property $prop $obj] }
    if {$cur eq $value} { return 1 }
    return [demo_try $what [list set_property $prop $value $obj]]
}

proc demo_ila {kind} {
    # kind = spi | wave -> the hw_ila object whose cell name contains ila_<kind>
    set ilas [get_hw_ilas -quiet -of_objects [current_hw_device] -filter "CELL_NAME =~ *ila_$kind*"]
    if {[llength $ilas] == 0} {
        # fall back to the probe set: the wave ILA has no dbg_adc_cs_n probe
        foreach ila [get_hw_ilas -quiet -of_objects [current_hw_device]] {
            set has_cs [llength [get_hw_probes -quiet -of_objects $ila -filter "NAME =~ *$::demo_probe(cs_n)*"]]
            if {($kind eq "spi" && $has_cs) || ($kind eq "wave" && !$has_cs)} { lappend ilas $ila }
        }
    }
    if {[llength $ilas] == 0} { error "no ILA of kind '$kind' found (run demo_connect; is the .ltx attached?)" }
    return [lindex $ilas 0]
}

proc demo_probe_width {p} {
    # Vivado 2025.2 calls it WIDTH, older versions PROBE_WIDTH.
    if {![catch {get_property WIDTH $p} w] && $w ne ""} { return $w }
    return [demo_probe_width $p]
}

proc demo_probe_obj {ila name} {
    # Vivado 2025.2 (System ILA): NAME is the generic spi_demo_bd_i/ila_spi/U0/probeN,
    # the block-design net name sits in NAME.CUSTOM (what the GUI displays).
    set p [list]
    set rx "^(.*/)?[string map {[ \\[ ] \\]} $name](_\\d+)?(\\\[\\d+(:\\d+)?\\\])?\$"
    foreach cand [get_hw_probes -quiet -of_objects $ila] {
        set cn ""
        catch { set cn [get_property NAME.CUSTOM $cand] }
        if {$cn ne "" && [regexp $rx $cn]} { lappend p $cand }
    }
    if {[llength $p] > 0} {
        if {[llength $p] > 1} { demo_msg WARNING "probe '$name' is ambiguous on [get_property NAME $ila]: $p - using the first" }
        return [lindex $p 0]
    }
    # Exact name first. When one net feeds both ILAs, write_debug_probes keeps the
    # hw_probe names unique across the device by appending _<n> to one of them
    # (seen in 2023.1: dbg_adc_sample_1), and a 1-bit probe may carry a [0]
    # suffix - accept "<name>", "<name>_<n>" and "<name>[0]", nothing else.
    set p [get_hw_probes -quiet -of_objects $ila $name]
    if {[llength $p] == 0} {
        set p [get_hw_probes -quiet -of_objects $ila -regexp $rx]
    }
    if {[llength $p] == 0} { error "probe '$name' not found on [get_property NAME $ila] (probes: [get_hw_probes -of_objects $ila])" }
    if {[llength $p] > 1} { demo_msg WARNING "probe '$name' is ambiguous on [get_property NAME $ila]: $p - using the first" }
    return [lindex $p 0]
}

proc demo_dontcare {width} {
    # don't-care compare value for a probe of the given width
    if {$width == 1} { return "eq1'bX" }
    return "eq${width}'h[string repeat X [expr {($width + 3) / 4}]]"
}

proc demo_reset_compares {ila} {
    # all probes back to don't care for both trigger and capture comparators
    foreach p [get_hw_probes -of_objects $ila] {
        set w [demo_probe_width $p]
        demo_try "reset trigger compare of [get_property NAME $p]" { set_property TRIGGER_COMPARE_VALUE [demo_dontcare $w] $p }
        catch { set_property CAPTURE_COMPARE_VALUE [demo_dontcare $w] $p }
    }
}

# ------------------------------------------------------------------------------
# demo_connect: hardware manager -> hw_server -> target -> K26 -> probes file
# ------------------------------------------------------------------------------
proc demo_connect {} {
    catch { open_hw_manager }
    if {[llength [get_hw_servers -quiet]] == 0} { connect_hw_server -url $::hw_server }
    if {[llength [get_hw_targets -quiet]] == 0} { error "no JTAG target - KR260 powered and USB-JTAG (J4) connected?" }
    if {[catch {current_hw_target}]} {
        set t [get_hw_targets]
        if {$::jtag_target ne ""} { set t [get_hw_targets $::jtag_target] }
        current_hw_target [lindex $t 0]
    }
    if {![get_property IS_OPENED [current_hw_target]]} { open_hw_target }
    set devs [get_hw_devices -quiet $::hw_device]
    if {[llength $devs] == 0} { error "no device matching '$::hw_device' (devices: [get_hw_devices])" }
    current_hw_device [lindex $devs 0]
    if {[file exists $::ltx_file]} {
        set_property PROBES.FILE      $::ltx_file [current_hw_device]
        set_property FULL_PROBES.FILE $::ltx_file [current_hw_device]
    } else {
        demo_msg WARNING "probes file not found: $::ltx_file (pass -ltx or set ::ltx_file)"
    }
    refresh_hw_device [current_hw_device]
    set ilas [get_hw_ilas -quiet -of_objects [current_hw_device]]
    demo_msg INFO "connected: [current_hw_device], ILAs: $ilas"
    if {[llength $ilas] != 2} { demo_msg WARNING "expected 2 ILAs (ila_spi, ila_wave), found [llength $ilas]" }
    set ::demo_setup_done 0
    return $ilas
}

# ------------------------------------------------------------------------------
# demo_setup: trigger / capture / display configuration of both ILAs
# ------------------------------------------------------------------------------
proc demo_setup {} {
    if {[llength [get_hw_ilas -quiet]] == 0} { demo_connect }

    # ---- ila_spi: capture ALWAYS, trigger on the falling edge of CS -------------
    set ila [demo_ila spi]
    demo_msg INFO "configuring [get_property NAME $ila] (cell [get_property CELL_NAME $ila])"
    demo_reset_compares $ila
    demo_set "ila_spi capture mode" CONTROL.CAPTURE_MODE ALWAYS $ila
    demo_set "ila_spi trigger mode" CONTROL.TRIGGER_MODE BASIC_ONLY $ila
    demo_set "ila_spi trigger condition" CONTROL.TRIGGER_CONDITION AND $ila
    demo_set "ila_spi data depth" CONTROL.DATA_DEPTH 4096 $ila
    demo_set "ila_spi window count" CONTROL.WINDOW_COUNT 1 $ila
    demo_set "ila_spi trigger position" CONTROL.TRIGGER_POSITION $::demo_trigger_position_spi $ila
    # F = falling transition (1 -> 0) of the 1-bit probe (UG908 compare value syntax)
    demo_try "ila_spi trigger on CS falling" { set_property TRIGGER_COMPARE_VALUE eq1'bF [demo_probe_obj $ila $::demo_probe(cs_n)] }
    # radix: decoded words unsigned, the raw 16-bit shift register binary ("MSB first" punchline)
    foreach {key radix} [list] {   ;# ila_spi carries only 1-bit pin probes now
        demo_try "ila_spi radix $key" { set_property DISPLAY_RADIX $radix [demo_probe_obj $ila $::demo_probe($key)] }
    }

    # ---- ila_wave: capture control, one row per ADC conversion ---------------
    set ilw [demo_ila wave]
    demo_msg INFO "configuring [get_property NAME $ilw] (cell [get_property CELL_NAME $ilw])"
    demo_reset_compares $ilw
    demo_set "ila_wave capture mode" CONTROL.CAPTURE_MODE BASIC $ilw
    demo_set "ila_wave capture condition" CONTROL.CAPTURE_CONDITION AND $ilw
    demo_set "ila_wave trigger mode" CONTROL.TRIGGER_MODE BASIC_ONLY $ilw
    demo_set "ila_wave trigger condition" CONTROL.TRIGGER_CONDITION AND $ilw
    demo_set "ila_wave data depth" CONTROL.DATA_DEPTH 8192 $ilw
    demo_set "ila_wave window count" CONTROL.WINDOW_COUNT 1 $ilw
    demo_set "ila_wave trigger position" CONTROL.TRIGGER_POSITION 0 $ilw
    set pv [demo_probe_obj $ilw $::demo_probe(wav_sample_valid)]
    # the software toggles adc_valid once per ADC sample: store on BOTH edges (B)
    demo_try "ila_wave capture condition adc_valid toggles" { set_property CAPTURE_COMPARE_VALUE eq1'bB $pv }
    demo_try "ila_wave trigger adc_valid toggles"           { set_property TRIGGER_COMPARE_VALUE eq1'bB $pv }
    foreach key {wav_sample wav_dac_code wav_zeros} {
        demo_try "ila_wave radix $key" { set_property DISPLAY_RADIX UNSIGNED [demo_probe_obj $ilw $::demo_probe($key)] }
    }
    set ::demo_setup_done 1
    demo_msg INFO "setup done - demo_arm is the one click"
}

# ------------------------------------------------------------------------------
# Display helper: GUI waveform (with the saved .wcfg if present), CSV in batch
# ------------------------------------------------------------------------------
proc demo_show {ila kind} {
    set data [current_hw_ila_data]
    set wcfg [file join $::wcfg_dir "ila_$kind.wcfg"]
    set shown 0
    # Vivado 2025.2: "display_hw_ila_data -wcfg" is refused in labtools hardware mode
    # (create_wave_config not supported) and the failed attempt also breaks the plain
    # display that follows. The waveform window of each ILA is created by the first
    # upload of the session and reused by every later one, with its radix, style and
    # zoom kept (checked 17 Oct 2026) - so the analog style is set once, by hand, after
    # the test click at T-22. The .wcfg route stays only for older Vivado versions.
    if {[file exists $wcfg] && ![string match "2025.*" [version -short]] && ![string match "2026.*" [version -short]]} {
        set shown [demo_try "display with $wcfg" { display_hw_ila_data -wcfg $wcfg $data }]
    }
    if {!$shown} {
        if {[catch {display_hw_ila_data $data} msg]} {
            # no GUI (batch mode): write a CSV instead
            file mkdir $::output_dir
            set csv [file join $::output_dir "ila_${kind}_[clock format [clock seconds] -format %Y%m%d_%H%M%S].csv"]
            write_hw_ila_data -csv_file -force $csv $data
            demo_msg INFO "no waveform window ($msg) - data written to $csv"
        } else {
            if {$kind eq "wave"} { demo_try "analog style for the sample bus" { demo_set_analog $::demo_probe(wav_sample) } }
        }
    }
}

# Best effort: set the analog style on the ADC sample wave of the current waveform
# window. The wave-object property names are those of the Vivado waveform viewer;
# if they differ in this version the failure is only reported (the .wcfg route
# always works). Prints the available properties on failure for the bench check.
proc demo_set_analog {probe_name} {
    set wc [current_wave_config]
    foreach w [get_waves -of $wc -filter "NAME =~ *$probe_name*" *] {   ;# get_waves needs a pattern argument
        if {[catch {
            set_property RADIX unsigned $w
            set_property WAVE_STYLE ANALOG $w
            set_property ANALOG_MIN 0 $w
            set_property ANALOG_MAX 4095 $w
        } msg]} {
            demo_msg WARNING "analog style via Tcl not accepted ($msg); wave properties: [list_property $w]"
            demo_msg WARNING "use the GUI once: right-click $probe_name > Waveform Style > Analog, then save the .wcfg to $::wcfg_dir"
            return
        }
    }
}

# ------------------------------------------------------------------------------
# demo_arm: THE one click. Arms ila_spi, waits, uploads, displays the SPI transaction.
# Only this ILA, so the window that comes to the front is never ambiguous (in the
# 2025.2 GUI every upload refreshes its own ILA dashboard). The encore has its own
# click: demo_arm_wave.
# ------------------------------------------------------------------------------
proc demo_arm {} {
    if {[llength [get_hw_ilas -quiet]] == 0} { demo_connect }
    if {!$::demo_setup_done} { demo_setup }
    set spi [demo_ila spi]
    run_hw_ila $spi
    if {[catch {wait_on_hw_ila -timeout $::demo_wait_timeout_min $spi} msg]} {
        demo_msg WARNING "[get_property NAME $spi] did not trigger within [expr {int($::demo_wait_timeout_min * 60)}] s ($msg) - is the loop running (heartbeat LED)?"
    }
    upload_hw_ila_data $spi
    demo_show $spi spi
    demo_msg INFO "SPI view ready - look for CS falling, 16 SCLK falling edges, MISO: 0 0 0 0 then DB11 first"
}

# Encore (second click): arm ila_wave (fills in ≈ 0.25 s: 8192 conversions), upload, show.
# rearm=0 only re-displays data uploaded earlier in the session.
proc demo_arm_wave {{rearm 1}} {
    if {[llength [get_hw_ilas -quiet]] == 0} { demo_connect }
    if {!$::demo_setup_done} { demo_setup }
    set wave [demo_ila wave]
    if {$rearm} {
        run_hw_ila $wave
        if {[catch {wait_on_hw_ila -timeout $::demo_wait_timeout_min $wave} msg]} {
            demo_msg WARNING "[get_property NAME $wave] did not trigger ($msg)"
        }
        upload_hw_ila_data $wave
    } else {
        catch { current_hw_ila_data [upload_hw_ila_data -quiet $wave] }
    }
    demo_show $wave wave
    demo_msg INFO "waveform view ready - adc_sample as analog = the sine is back"
}

# Batch alternative / archive: arm, wait, upload and write both captures as CSV.
proc demo_save_csv {} {
    if {[llength [get_hw_ilas -quiet]] == 0} { demo_connect }
    if {!$::demo_setup_done} { demo_setup }
    file mkdir $::output_dir
    set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
    foreach kind {wave spi} {
        set ila [demo_ila $kind]
        run_hw_ila $ila
        catch { wait_on_hw_ila -timeout $::demo_wait_timeout_min $ila }
        set data [upload_hw_ila_data $ila]
        set csv [file join $::output_dir "ila_${kind}_$stamp.csv"]
        write_hw_ila_data -csv_file -force $csv $data
        demo_msg INFO "written $csv"
    }
}

# Prints the ILA control properties and the probe compare values (bench check of
# the property names used above).
proc demo_status {} {
    foreach ila [get_hw_ilas -quiet] {
        demo_msg INFO "==== [get_property NAME $ila]  cell=[get_property CELL_NAME $ila]"
        foreach p [lsort [list_property $ila]] {
            if {[string match "CONTROL.*" $p]} { demo_msg INFO [format "  %-32s = %s" $p [get_property $p $ila]] }
        }
        foreach pr [get_hw_probes -of_objects $ila] {
            set cap ""
            catch { set cap [get_property CAPTURE_COMPARE_VALUE $pr] }
            demo_msg INFO [format "  probe %-22s w=%-3s trig=%-12s cap=%-12s radix=%s" [get_property NAME $pr] [demo_probe_width $pr] [get_property TRIGGER_COMPARE_VALUE $pr] $cap [get_property DISPLAY_RADIX $pr]]
        }
    }
}

proc demo_help {} {
    puts "hw_demo.tcl procs:"
    puts "  demo_connect        connect hw_server/target/K26, attach $::ltx_file, refresh"
    puts "  demo_setup          trigger CS falling (ila_spi), capture wav_adc_sample_valid=1 (ila_wave), radix"
    puts "  demo_arm            ONE CLICK: arm ila_spi, wait, upload, show the SPI transaction"
    puts "  demo_arm_wave ?0?   ENCORE click: arm ila_wave, upload, show the reconstructed sine (0 = no re-arm)"
    puts "  demo_save_csv       arm/upload both and write CSVs to $::output_dir"
    puts "  demo_status         print ILA CONTROL.* properties and probe compare values"
    puts "  .wcfg files used when present: [file join $::wcfg_dir ila_spi.wcfg], [file join $::wcfg_dir ila_wave.wcfg]"
}
demo_help
if {$::autoconnect} {
    if {[catch {demo_connect; demo_setup} msg]} {
        demo_msg WARNING "autoconnect failed: $msg - connect the KR260 and run demo_connect; demo_setup"
    }
}
