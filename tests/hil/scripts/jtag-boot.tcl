# tests/hil/scripts/jtag-boot.tcl - boot the ZUBoard 1CG over JTAG with xsdb.
#
# Board: SW2 = ON-ON-ON-ON (JTAG boot mode), J16 micro-USB to the host.
# Loads the boot chain that `make sw-image` collects into out/sw/jtag/:
#   1. PMUFW  -> PMU MicroBlaze
#   2. FSBL   -> A53 #0; psu_init sets up MIO, clocks and DDR, then the FSBL
#                stops because the boot mode is JTAG
#   3. system.dtb @ 0x100000 (U-Boot's control DT), optional boot.scr,
#      U-Boot and TF-A; execution starts in TF-A (BL31), which enters U-Boot.
# Same sequence that petalinux-boot --jtag generates for ZynqMP.
#
# Usage:  xsdb tests/hil/scripts/jtag-boot.tcl <jtag-dir> [boot.scr]
# Env:    HW_SERVER_URL  hw_server to use, e.g. tcp:localhost:3121
#                        (default: xsdb starts a local one)
#         JTAG_CABLE     cable serial filter, when several boards are attached
#         JTAG_RESET     1 (default): system reset first, so reruns start clean
#         FSBL_WAIT_MS   time given to the FSBL for psu_init (default 5000)
#         SCRIPT_ADDR    DDR address for boot.scr (default 0x20000000)

proc die {m} { puts stderr "jtag-boot: ERROR: $m"; catch {disconnect}; exit 1 }
proc say {m} { puts "jtag-boot: $m"; flush stdout }
proc envor {name def} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $def
}

# ---- arguments ------------------------------------------------------------------
if {[llength $argv] < 1 || [llength $argv] > 2} {
  die "usage: xsdb jtag-boot.tcl <jtag-dir> \[boot.scr\]"
}
set dir [file normalize [lindex $argv 0]]
set scr ""
if {[llength $argv] == 2} { set scr [file normalize [lindex $argv 1]] }

foreach f {pmufw.elf fsbl.elf bl31.elf u-boot.elf system.dtb} {
  if {![file isfile [file join $dir $f]]} {
    die "missing [file join $dir $f] (run 'make sw-image')"
  }
}
if {$scr ne "" && ![file isfile $scr]} { die "missing $scr (run 'make hil-stage')" }

set fsbl_wait   [envor FSBL_WAIT_MS 5000]
set script_addr [envor SCRIPT_ADDR 0x20000000]
set cable       [envor JTAG_CABLE ""]
set cable_filter ""
if {$cable ne ""} { set cable_filter " && jtag_cable_serial =~ \"$cable\"" }

# ---- helpers --------------------------------------------------------------------
# Select a target, retrying while the JTAG chain settles (after power-up/reset).
proc tgt {pattern} {
  global cable_filter
  set filter "name =~ \"$pattern\"$cable_filter"
  for {set i 0} {$i < 40} {incr i} {
    if {![catch {targets -set -nocase -filter $filter}]} { return }
    after 250
  }
  puts stderr [targets]
  die "no JTAG target matching '$pattern' (board on? J16 connected? cable held by another hw_server?)"
}

# In JTAG boot mode the CSU keeps the PMU MicroBlaze off the debug chain.
# CSU JTAG_SEC: open the security gates so xsdb can see and load the PMU.
proc open_gates {} {
  tgt "*PSU*"
  mask_write 0xFFCA0038 0x1C0 0x1C0
}

# ---- connect ----------------------------------------------------------------------
set url [envor HW_SERVER_URL ""]
if {$url ne ""} { connect -url $url } else { connect }
say "connected"

open_gates
if {[envor JTAG_RESET 1]} {
  say "system reset"
  tgt "*APU*"
  if {[catch {rst -system} e]} { say "system reset failed ($e), continuing without it" }
  after 1500
  open_gates
}

# CRL_APB BOOT_MODE_USER[3:0] = boot mode pins. Anything but 0 means the boot
# ROM tried (and maybe failed on) another device first.
tgt "*APU*"
set mode [expr {[mrd -force -value 0xFF5E0200] & 0xf}]
if {$mode != 0} {
  die "boot mode pins read [format 0x%x $mode], not JTAG (0x0): set SW2 to ON-ON-ON-ON and power-cycle"
}

# ---- 1. PMUFW ---------------------------------------------------------------------
say "PMUFW -> PMU"
tgt "*MicroBlaze PMU*"
catch {stop}
after 500
dow -force [file join $dir pmufw.elf]
con
after 1000

# ---- 1b. Keep POWER_KILL_N (MIO34) high -------------------------------------------
# The FSBL's psu_init muxes MIO34 to the PMU's GPO. That output (PMU_IOMODULE GPO1,
# bit 2 = MIO34) resets to 0, which asserts POWER_KILL_N: the on/off controller (U29)
# then cuts board power within milliseconds. Preset the output high before the FSBL runs.
# Only bit 2 is written; bits 0/1 (MIO32/33) are plain GPIO in this design.
say "PMU GPO: MIO34 (POWER_KILL_N) high"
tgt "*MicroBlaze PMU*"
catch {stop}
mwr 0xFFD40014 0x4
con

# ---- 2. FSBL ----------------------------------------------------------------------
say "FSBL -> A53 #0 (psu_init: MIO, clocks, DDR)"
tgt "*APU*"
# A53 #0 is held in reset in JTAG mode. Park it on a branch-to-self at the OCM
# reset vector, then release it (CRF_APB RST_FPD_APU) so it can be loaded.
mwr 0xffff0000 0x14000000
mask_write 0xFD1A0104 0x501 0x0
tgt "*A53*#0"
catch {stop}
dow -force [file join $dir fsbl.elf]
con
after $fsbl_wait
catch {stop}

# ---- 3. DTB, boot script, U-Boot, TF-A --------------------------------------------
say "system.dtb @ 0x100000, U-Boot, TF-A"
tgt "*A53*#0"
dow -data [file join $dir system.dtb] 0x100000
if {$scr ne ""} {
  say "boot.scr @ $script_addr"
  dow -data $scr $script_addr
}
dow -force [file join $dir u-boot.elf]
# Loaded last, so the PC is set to its entry: TF-A starts first, then U-Boot.
dow -force [file join $dir bl31.elf]
con

say "running: U-Boot should now print on the J16 UART (115200 8N1)"
if {$scr ne ""} {
  say "if autoboot does not run the netboot script, stop autoboot and type: source $script_addr"
}
disconnect
