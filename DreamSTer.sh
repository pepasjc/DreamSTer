#!/usr/bin/env python3
"""DreamSTer Hybrid Core - terminal UI for minicast / polly2-rtl.

Python 3.9 / curses. Scans gane dir for .cdi/.cue/.gdi images,
lets the user tweak emu.cfg and launches minicast on the polly2-rtl bitstream.

The MiSTer main binary is killed as soon as the script starts (so it stops
eating input/video) and is ALWAYS restarted when the script exits, on every
path. Menus navigate from the terminal keyboard (console tty or ssh pty) and
from any configured evdev device: mapped dpad moves, A confirms; leaving
a screen is always an explicit Back/Exit menu entry.
"""

import configparser
import curses
import errno
import fcntl
import glob
import json
import mmap
import os
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time

TITLE = "DreamSTer (CRT 15 kHz)"

SYSTEM_DIR = "/media/fat/games/Dreamcast"
USB_GAME_DIR_GLOB = "/media/usb*/games/Dreamcast"
STARTUP_STORAGE_READY_AT = 30.0
STORAGE_POLL_INTERVAL = 0.5
BOOT_BIN = os.path.join(SYSTEM_DIR, "dc_boot.bin")
FLASH_BIN = os.path.join(SYSTEM_DIR, "dc_flash.bin")
CFG_PATH = os.path.join(SYSTEM_DIR, "emu.cfg")

# [dreamster] Version stamp; a cfg without exactly this value is from a
# different release and is reset (after a warning) before the UI runs.
CFG_VERSION = "r6"

MINICAST_DIR = "/media/fat/minicast"
LOAD_BITSTREAM = os.path.join(MINICAST_DIR, "load_fpga_bitstream")
# CRT build: 15 kHz polly2 bitstream + ADV7513 15 kHz setup (see crt/README)
# CRT bitstreams per video mode (15 kHz raster built into the FPGA image)
CRT_BITSTREAMS = {
    "240p": os.path.join(MINICAST_DIR, "polly2-rtl-crt240p-r7-75.rbf"),
    "480i": os.path.join(MINICAST_DIR, "polly2-rtl-crt480i-r7-75.rbf"),
    # r7 + upstream's experimental modifier volumes (character shadows):
    # one unified bitstream for both - 240p/480i picked by CRT_CTRL[3],
    # RGB/YPbPr by CRT_CTRL[4], and Template's video-DAC control pins, so the
    # same file drives resistor carriers (MiSTercade) and DAC boards
    # (SuperStation's ADV7125)
    "240p-mv": os.path.join(MINICAST_DIR, "polly2-rtl-crt-r7mv-unified.rbf"),
    "480i-mv": os.path.join(MINICAST_DIR, "polly2-rtl-crt-r7mv-unified.rbf"),
}
BITSTREAM_RBF = CRT_BITSTREAMS["240p"]
# YPbPr needs the unified bitstream whatever the video mode (the non-shadow
# 240p/480i builds are RGB-only resistor-carrier builds)
YPBPR_RBF = os.path.join(MINICAST_DIR, "polly2-rtl-crt-r7mv-unified.rbf")
HDMI15K = os.path.join(MINICAST_DIR, "hdmi15k.py")
MEM_WC = os.path.join(MINICAST_DIR, "mem_wc.ko")
# prefer a mem_wc built for the running kernel (the r6 one targets 5.15.1-MiSTer)
_MEM_WC_KVER = os.path.join(MINICAST_DIR, "mem_wc-%s.ko" % os.uname().release)
if os.path.exists(_MEM_WC_KVER):
    MEM_WC = _MEM_WC_KVER
SETUP_HDMI = os.path.join(MINICAST_DIR, "setup_hdmi")
MINICAST_ELF = os.path.join(MINICAST_DIR, "minicast.elf")
# CRT build of minicast (saves the Dreamcast flash / BIOS settings on exit,
# SIGTERM-safe for the Start+L hotkey); stock binary as fallback
if os.path.exists(os.path.join(MINICAST_DIR, "minicast-crt-r7.elf")):
    MINICAST_ELF = os.path.join(MINICAST_DIR, "minicast-crt-r7.elf")
MISTER_BIN = "/media/fat/MiSTer"
MENU_RBF = "/media/fat/menu.rbf"

# Pixel UI (minicast/dsui.py): the menus drawn on the Linux framebuffer in
# the look of the emulator's own in-game lists. Without it (module missing,
# no framebuffer, not on the console, DREAMSTER_UI=curses) the plain curses
# UI is used.
if MINICAST_DIR not in sys.path:
    sys.path.append(MINICAST_DIR)
try:
    import dsui
except ImportError:
    dsui = None

GAME_EXTS = (".cdi", ".cue", ".gdi")

KEY_ENTER = (curses.KEY_ENTER, 10, 13)

with open("/tmp/CORENAME", "w") as text_file:
    print(f"DREAMCAST", file=text_file)

# There is deliberately NO ESC/B "back" shortcut: a laggy arrow-key escape
# sequence decays into a bare tty ESC, which used to quit menus at random.
# tty ESC (and any other unmapped key) is ignored; every screen navigates
# through explicit Back/Exit menu entries instead.

DEFAULT_CFG = """\
[audio]
backend = auto
disable = 0

[config]
Cloudroms.HideHomebrew = no
Cloudroms.ShowArchiveOrg = no
Debug.SerialConsoleEnabled = no
Debug.VirtualSerialPort = no
Debug.VirtualSerialPortFile =
Dreamcast.Broadcast = 0
Dreamcast.Cable = 0
Dreamcast.ContentPath =
Dreamcast.FullMMU = no
Dreamcast.Language = 6
Dreamcast.Region = 1
Dynarec.DspEnabled = 1
Dynarec.Enabled = yes
Dynarec.ScpuEnabled = 1
Dynarec.SmcCheckLevel = 0
Dynarec.idleskip = yes
Dynarec.opt_constprop = 2
Dynarec.opt_cyclecheck_backwards_only = yes
Dynarec.opt_div1_som = yes
Dynarec.opt_fipr_w = yes
Dynarec.opt_readm_pairs = no
Dynarec.opt_sqw_on_pref = no
Dynarec.opt_sqw_rewrite = no
Dynarec.safe-mode = yes
Dynarec.unstable-opt = no
Freerunning = no
SavePopup.isShown = no
Social.HideCallToAction = no
aica.LimitFPS = yes
aica.NoBatch = no
aica.NoSound = no
polly2.AutoReset = yes
polly2.ClockSel = 3
polly2.DumpOnLockup = no
pvr.FPSTarget = 66
pvr.ForceGLES2 = no
pvr.MaxThreads = 3
pvr.MultithreadedTA = 2
pvr.SynchronousRendering = no
pvr.backend = auto
rend.Clipping = yes
rend.CustomTextures = no
rend.DumpTextures = no
rend.FloatVMUs = no
rend.Fog = yes
rend.MaxFilteredTextureSize = 256
rend.ModifierVolumes = yes
rend.RenderToTextureBuffer = no
rend.RenderToTextureUpscale = 1
rend.Rotate90 = no
rend.ScreenOrientation = 0
rend.ScreenScaling = 100
rend.ScreenStretching = 100
rend.ShowFPS = no
rend.TextureUpscale = 1
rend.WideScreen = no
ta.skip = 0

[dreamster]
OptMode = balanced
Overclock = 0
Version = r6

[input]
MouseSensitivity = 100
VirtualGamepadVibration = 20
device1 = 0
device1.1 = 1
device1.2 = 1
device2 = 8
device2.1 = 8
device2.2 = 8
device3 = 8
device3.1 = 8
device3.2 = 8
device4 = 8
device4.1 = 8
device4.2 = 8
"""


# ---------------------------------------------------------------- config ---

class Option:
    def __init__(self, label, key, choices, default, enabled=None,
                 section="config"):
        self.label = label
        self.section = section
        self.key = key                 # key inside [section]
        self.choices = choices         # list of (value, display)
        self.default = default
        self._enabled = enabled        # callable(cfg) -> bool, None = always

    def enabled(self, cfg):
        return self._enabled(cfg) if self._enabled else True

    def current(self, cfg):
        return cfg.get(self.section, self.key, fallback=self.default).strip()

    def display(self, cfg):
        val = self.current(cfg)
        for v, name in self.choices:
            if v == val:
                return name
        return "? (%s)" % val

    def set(self, cfg, value):
        if not cfg.has_section(self.section):
            cfg.add_section(self.section)
        cfg.set(self.section, self.key, value)

    def cycle(self, cfg, direction):
        val = self.current(cfg)
        idx = next((i for i, (v, _) in enumerate(self.choices) if v == val), -1)
        idx = (idx + direction) % len(self.choices)
        self.set(cfg, self.choices[idx][0])


class RegionOption(Option):
    """Console region; the matching Broadcast standard is written with it."""

    BROADCAST = {"1": "0", "0": "0", "2": "1"}  # US/JP -> NTSC, EU -> PAL

    def __init__(self):
        Option.__init__(self, "Region", "Dreamcast.Region",
                        [("1", "NTSC-US"), ("0", "NTSC-JP"), ("2", "PAL")],
                        "1")

    def set(self, cfg, value):
        Option.set(self, cfg, value)
        cfg.set("config", "Dreamcast.Broadcast", self.BROADCAST[value])


class AudioOption(Option):
    """Audio mode: [config] aica.LimitFPS + [audio] disable together.

    Synced   = LimitFPS yes, disable 0  (audio FIFO paces the emu)
    Unsynced = LimitFPS no,  disable 0  (drop samples rather than wait)
    Off      = disable 1                (LimitFPS left as-is)

    Values match the DEFAULT_CFG template: aica.LimitFPS is yes/no,
    [audio] disable is 0/1.
    """

    def __init__(self):
        Option.__init__(self, "Audio", "aica.LimitFPS",
                        [("synced", "Synced"), ("unsynced", "Unsynced"),
                         ("off", "Off")], "synced")

    def current(self, cfg):
        if cfg.get("audio", "disable", fallback="0").strip() == "1":
            return "off"
        v = cfg.get("config", self.key, fallback="yes").strip().lower()
        return "synced" if v in ("yes", "true", "on", "1") else "unsynced"

    def set(self, cfg, value):
        for section in ("audio", "config"):
            if not cfg.has_section(section):
                cfg.add_section(section)
        cfg.set("audio", "disable", "1" if value == "off" else "0")
        if value != "off":
            cfg.set("config", self.key, "yes" if value == "synced" else "no")

    def cycle(self, cfg, direction):
        val = self.current(cfg)
        idx = next(i for i, (v, _) in enumerate(self.choices) if v == val)
        self.set(cfg, self.choices[(idx + direction) % len(self.choices)][0])


def _is_freerunning(cfg):
    # same truthy set as minicast's cfgLoadBool
    v = cfg.get("config", "Freerunning", fallback="no").strip().lower()
    return v in ("yes", "true", "on", "1")


# ------------------------------------------------- optimization presets ---

def opt_mode(cfg):
    v = cfg.get("dreamster", "OptMode", fallback="balanced").strip().lower()
    return v if v in OPT_PRESETS or v == "custom" else "balanced"


def _opt_custom(cfg):
    return opt_mode(cfg) == "custom"


OPT_BOOL = [("no", "Off"), ("yes", "On")]

# the expanded optimization set; grayed out (values driven by the preset)
# unless Optimizations = Custom. Defaults are the Balanced preset.
OPT_ITEMS = [
    Option("  Async GDROM", "gdrom.AsyncDMA",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  Div1 Matching", "Dynarec.opt_div1_som",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  Constprop", "Dynarec.opt_constprop",
           [("0", "Off"), ("1", "Safe"), ("2", "Include same page")], "2",
           enabled=_opt_custom),
    Option("  FIPR Constant W", "Dynarec.opt_fipr_w",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  Multithreaded TA", "pvr.MultithreadedTA",
           [("0", "Off"), ("1", "Safe"), ("2", "Fully Async")], "2",
           enabled=_opt_custom),
    Option("  Reduced Cycle Checks", "Dynarec.opt_cyclecheck_backwards_only",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  SQW On Pref", "Dynarec.opt_sqw_on_pref",
           OPT_BOOL, "no", enabled=_opt_custom),
    Option("  SQW Static Rewrite", "Dynarec.opt_sqw_rewrite",
           OPT_BOOL, "no", enabled=_opt_custom),
    Option("  ReadMem Pairing", "Dynarec.opt_readm_pairs",
           OPT_BOOL, "no", enabled=_opt_custom),
]

# preset name -> {cfg key: value} over exactly the OPT_ITEMS keys
OPT_PRESETS = {
    "none": {
        "gdrom.AsyncDMA": "no",
        "Dynarec.opt_div1_som": "no",
        "Dynarec.opt_constprop": "0",
        "Dynarec.opt_fipr_w": "no",
        "pvr.MultithreadedTA": "0",
        "Dynarec.opt_cyclecheck_backwards_only": "no",
        "Dynarec.opt_sqw_on_pref": "no",
        "Dynarec.opt_sqw_rewrite": "no",
        "Dynarec.opt_readm_pairs": "no",
    },
    "safe": {
        "gdrom.AsyncDMA": "yes",
        "Dynarec.opt_div1_som": "yes",
        "Dynarec.opt_constprop": "1",
        "Dynarec.opt_fipr_w": "yes",
        "pvr.MultithreadedTA": "1",
        "Dynarec.opt_cyclecheck_backwards_only": "no",
        "Dynarec.opt_sqw_on_pref": "no",
        "Dynarec.opt_sqw_rewrite": "no",
        "Dynarec.opt_readm_pairs": "no",
    },
    "balanced": {
        "gdrom.AsyncDMA": "yes",
        "Dynarec.opt_div1_som": "yes",
        "Dynarec.opt_constprop": "2",
        "Dynarec.opt_fipr_w": "yes",
        "pvr.MultithreadedTA": "2",
        "Dynarec.opt_cyclecheck_backwards_only": "yes",
        "Dynarec.opt_sqw_on_pref": "no",
        "Dynarec.opt_sqw_rewrite": "no",
        "Dynarec.opt_readm_pairs": "no",
    },
    "max": {
        "gdrom.AsyncDMA": "yes",
        "Dynarec.opt_div1_som": "yes",
        "Dynarec.opt_constprop": "2",
        "Dynarec.opt_fipr_w": "yes",
        "pvr.MultithreadedTA": "2",
        "Dynarec.opt_cyclecheck_backwards_only": "yes",
        "Dynarec.opt_sqw_on_pref": "yes",
        "Dynarec.opt_sqw_rewrite": "yes",
        "Dynarec.opt_readm_pairs": "yes",
    },
}


class OptModeOption(Option):
    """Preset selector; choosing a preset writes its values to emu.cfg so
    minicast (and the grayed-out rows) always read the effective ones."""

    def __init__(self):
        Option.__init__(self, "Optimizations", "OptMode",
                        [("none", "None"), ("safe", "Safe"),
                         ("balanced", "Balanced"), ("max", "Max Speed"),
                         ("custom", "Custom")], "balanced",
                        section="dreamster")

    def current(self, cfg):
        return opt_mode(cfg)

    def set(self, cfg, value):
        Option.set(self, cfg, value)
        preset = OPT_PRESETS.get(value)
        if preset:
            for opt in OPT_ITEMS:
                opt.set(cfg, preset[opt.key])


REGION_OPT = RegionOption()
CABLE_OPT = Option("Cable Type", "Dreamcast.Cable",
                   [("0", "VGA"), ("3", "Composite")], "0")
OVERCLOCK_OPT = Option("Overclock", "Overclock",
                       [("0", "No overclock"), ("1", "1 GHz"),
                        ("2", "1.2 GHz (experimental)")], "0",
                       section="dreamster")
TIMEREC_OPT = Option("Time Reconciliation", "Freerunning",
                     [("no", "Prefer Video"), ("yes", "Prefer Audio")], "no")
AUDIO_OPT = AudioOption()
FPS_OPT = Option("FPS Target", "pvr.FPSTarget",
                 [("66", "60 FPS"), ("55", "50 FPS"),
                  ("33", "30 FPS"), ("28", "25 FPS")], "66",
                 enabled=lambda cfg: not _is_freerunning(cfg))
OPTMODE_OPT = OptModeOption()
AUTORESET_OPT = Option("AutoReset", "polly2.AutoReset", OPT_BOOL, "yes")
CLOCK_OPT = Option("Clock", "polly2.ClockSel",
                   [("0", "75 MHz"), ("1", "90 MHz"),
                    ("2", "100 MHz"), ("3", "112 MHz")], "3")
DUMP_OPT = Option("Store Crash Dump", "polly2.DumpOnLockup", OPT_BOOL, "no")

# CRT build: output volume (AUDIO_VOL register, MiSTer's 6 dB steps) and the
# core clock used while the CRT bitstream runs (it only holds timing at
# 75 MHz; faster ones are for testing and may lock up / auto-reset).
CRT_VOL_OPT = Option("Volume", "CrtVolume",
                     [("mister", "MiSTer volume")]
                     + [(str(n), "0 dB (max)" if n == 0 else "-%d dB" % (6 * n))
                        for n in range(8)]
                     + [("mute", "Mute")], "mister", section="dreamster")
# r7 test build: CLK bit [1] picks the core PLL's 75 / 112.5 MHz outputs
# emulator build: our r6 minicast, or upstream's unreleased r6b CPU work
# (tacore-opts: anchored/self loops, multiblock, faster TA writeout) with
# the same CRT fixes
CRT_EMU_OPT = Option("Emulator", "CrtEmulator",
                     [("fast", "r6b fast CPU"), ("perf", "r6b fast CPU + SQ (test)"),
                      ("audiothr", "SQ + audio thread + pad hotplug (test)"),
                      ("ra", "... + RetroAchievements (test)"),
                      ("stable", "r6 (stable)")],
                     "fast", section="dreamster")
# USB WiFi dongles share the DE10's single USB host (dwc2) with the
# sticks: with the game loading DDR, full-speed pad reports behind the hub
# get lost next to the dongle's high-speed traffic (missed presses, releases
# arriving seconds late -> menus scrolling by themselves). Detaching the
# dongle for the length of a game (same as unplugging it) fixes that; it
# re-enumerates and MiSTer's hotplug reconnects it on exit.
VIDEO_OPT = Option("Video mode", "CrtVideoMode",
                   [("240p", "240p (sharp, no flicker)"),
                    ("480i", "480i (full res, interlaced)"),
                    ("240p-mv", "240p + shadows"),
                    ("480i-mv", "480i + shadows")],
                   "480i-mv", section="dreamster")
# CRT_CTRL (0xFF202034, bitstreams with the 15 kHz vertical filter): [0]
# 480i field parity (1 = even source lines on the top field - correct; the
# first builds had it swapped), [2:1] vertical filter 0 off / 1 2-tap /
# 2 3-tap. Older bitstreams ignore the write.
# RetroAchievements (emulator builds with RA; login from
# /media/fat/retroachievements.cfg, softcore only). "Dry run" identifies the
# game and evaluates achievements but never submits an unlock.
RA_OPT = Option("RetroAchievements", "CrtRetroAchievements",
                [("dryrun", "On, dry run (nothing submitted)"),
                 ("on", "On (softcore)"), ("off", "Off")],
                "dryrun", section="dreamster")
# Unlock popups: "auto" leaves it to retroachievements.cfg (dreamster_popups,
# default on); On/Off are passed as MINICAST_RA_POPUPS. Also what the
# emulator's in-game menu changes (options_changed.json).
RA_POPUPS_OPT = Option("Achievement popups", "CrtRaPopups",
                       [("auto", "As retroachievements.cfg"), ("on", "On"),
                        ("off", "Off")],
                       "auto", section="dreamster")
# emulator builds with the audio feeder thread ([audio] threaded, read by
# minicast): Off restores the direct FIFO pushes from the emulation thread
AUDIO_THREAD_OPT = Option("Audio feeder thread", "threaded",
                          [("1", "On (faster)"), ("0", "Off (direct)")],
                          "1", section="audio")
VMU_OPT = Option("VMU saves", "CrtVmuPerGame",
                 [("game", "Per game (GameSync)"), ("shared", "Shared (one VMU)")],
                 "game", section="dreamster")
ANALOG_OPT = Option("Analog output", "CrtAnalog",
                    [("rgb", "RGB (csync)"), ("ypbpr", "YPbPr (component)")],
                    "rgb", section="dreamster")
FIELD_OPT = Option("480i field order", "CrtFieldOrder",
                   [("correct", "Correct"), ("original", "Original (swapped)")],
                   "correct", section="dreamster")
VFILTER_OPT = Option("Vertical filter", "CrtVFilter",
                     [("auto", "Auto (480i smooth, 240p off)"), ("off", "Off"),
                      ("light", "Light (2 lines)"), ("smooth", "Smooth (3 lines)")],
                     "auto", section="dreamster")
WIFI_OPT = Option("WiFi during games", "CrtWifiPause",
                  [("pause", "Pause (fixes lost inputs)"), ("keep", "Keep on")],
                  "pause", section="dreamster")
# One bitstream per fast clock: the r7 core clock is a hard 2:1 switch, so a
# build carries 75 MHz plus ONE fast slot (CLK bit 1). 112.5 MHz is the
# fastest but marginal (GPU hangs when the FPGA runs warm); 100 MHz is the
# same design with a 75 / 100 MHz PLL - "100" loads that file and selects its
# fast slot.
CRT_CLOCK_OPT = Option("CRT Clock (r7)", "CrtClockSelR7",
                       [("0", "75 MHz"), ("100", "100 MHz (stable when warm)"),
                        ("2", "112.5 MHz")], "100",
                       section="dreamster")
UNIFIED_100_RBF = os.path.join(MINICAST_DIR, "polly2-rtl-crt-r7mv-unified-100.rbf")

# every option Restore Defaults resets; OPTMODE last so the balanced preset
# is what ends up in the OPT_ITEMS keys
ALL_OPTIONS = [REGION_OPT, CABLE_OPT, OVERCLOCK_OPT, TIMEREC_OPT, AUDIO_OPT,
               FPS_OPT, AUTORESET_OPT, CLOCK_OPT, DUMP_OPT,
               CRT_VOL_OPT, VIDEO_OPT, ANALOG_OPT, FIELD_OPT, VFILTER_OPT, WIFI_OPT,
               VMU_OPT, RA_OPT, AUDIO_THREAD_OPT, RA_POPUPS_OPT,
               CRT_CLOCK_OPT,
               CRT_EMU_OPT] + OPT_ITEMS \
              + [OPTMODE_OPT]


# ------------------------------------------------- dreamcast peripherals ---
# [input] deviceN main maple device + deviceN.1/.2 expansion slots;
# MDT values: 0 controller, 1 VMU, 3 vibration pack, 4 keyboard, 5 mouse,
# 8 none.

PERIPHERALS = [
    ("none", "None", ("8", "8", "8")),
    ("pad_vmu_vib", "Gamepad + VMU + Vibration", ("0", "1", "3")),
    ("pad_2vmu", "Gamepad + 2x VMU", ("0", "1", "1")),
    ("keyboard", "Keyboard", ("4", "8", "8")),
    ("mouse", "Mouse", ("5", "8", "8")),
]
PERIPHERAL_LABELS = dict((pid, label) for pid, label, _ in PERIPHERALS)


def _periph_keys(port):
    d = "device%d" % (port + 1)
    return (d, d + ".1", d + ".2")


def get_port_peripheral(cfg, port):
    """Peripheral id for a port, or None if the cfg holds something else."""
    keys = _periph_keys(port)
    vals = tuple(cfg.get("input", k, fallback="8").strip() for k in keys)
    for pid, _, v in PERIPHERALS:
        if v[0] != vals[0]:
            continue
        # expansion slots only distinguish the controller flavors
        if vals[0] != "0" or v[1:] == vals[1:]:
            return pid
    return None


def set_port_peripheral(cfg, port, pid):
    vals = dict((p, v) for p, _, v in PERIPHERALS)[pid]
    if not cfg.has_section("input"):
        cfg.add_section("input")
    for key, val in zip(_periph_keys(port), vals):
        cfg.set("input", key, val)


def port_accepts(cfg, port, dev_kind):
    """Keyboard/Mouse ports only take matching devices; controller (and
    None/unknown) ports take anything - keyboards and mice can still act
    as gamepads there."""
    main = cfg.get("input", "device%d" % (port + 1), fallback="8").strip()
    if main == "4":
        return dev_kind == "keyboard"
    if main == "5":
        return dev_kind == "mouse"
    return True


def restore_defaults(cfg):
    """Everything back to stock: options, peripherals, input mappings."""
    for opt in ALL_OPTIONS:
        opt.set(cfg, opt.default)
    for port in range(4):
        set_port_peripheral(cfg, port, "pad_2vmu" if port == 0 else "none")
    for section in list(cfg.sections()):
        if re.match(r"input\d+$", section):
            cfg.remove_section(section)
    CONFIG.clear()
    PORTS.clear()
    # re-materialize the per-kind default mappings for connected devices
    # (all on Port A) so emu.cfg holds a working input config again
    save_input_config(cfg, scan_devices())


def reset_all_configuration():
    """Version-mismatch reset: rewrite emu.cfg from the pristine template
    (dropping any stale keys from other releases), then re-materialize
    default input mappings. Returns the fresh cfg."""
    try:
        with open(CFG_PATH, "w") as f:
            f.write(DEFAULT_CFG)
    except OSError:
        pass
    cfg = load_cfg()
    CONFIG.clear()
    PORTS.clear()
    save_input_config(cfg, scan_devices())
    return cfg


def load_cfg():
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str  # preserve key case
    if os.path.isfile(CFG_PATH):
        try:
            cfg.read(CFG_PATH)
        except configparser.Error:
            pass
    else:
        try:
            with open(CFG_PATH, "w") as f:
                f.write(DEFAULT_CFG)
        except OSError:
            pass
        cfg.read_string(DEFAULT_CFG)
    if not cfg.has_section("config"):
        cfg.add_section("config")
    return cfg


# ---- per-game settings -----------------------------------------------------
# A game can override any option. Its overrides live in their own small file
# (only the keys that differ); at launch they are laid over emu.cfg for the
# length of the game and the global values are put back afterwards.
GAME_CFG_DIR = os.path.join(SYSTEM_DIR, "dreamster-games")


def game_cfg_path(game):
    stem = "bios" if game == "nodisk" else \
        os.path.basename(game).rsplit(".", 1)[0]
    return os.path.join(GAME_CFG_DIR, re.sub(r"[^A-Za-z0-9._()\[\] -]+", "_", stem) + ".cfg")


def load_game_overrides(game):
    over = configparser.ConfigParser(interpolation=None)
    over.optionxform = str
    try:
        over.read(game_cfg_path(game))
    except configparser.Error:
        pass
    return over


class GameCfg:
    """emu.cfg with one game's overrides on top. Reads see the override when
    there is one; writes go to the game (per_game) or to the global cfg."""

    def __init__(self, base, over, game, per_game=False):
        self.base, self.over, self.game = base, over, game
        self.per_game = per_game

    def _target(self):
        return self.over if self.per_game else self.base

    def get(self, section, key, fallback=None, **kw):
        if self.over.has_option(section, key):
            return self.over.get(section, key)
        return self.base.get(section, key, fallback=fallback, **kw)

    def has_section(self, section):
        return self._target().has_section(section)

    def add_section(self, section):
        self._target().add_section(section)

    def set(self, section, key, value):
        self._target().set(section, key, value)
        if not self.per_game and self.over.has_option(section, key):
            # a global change for an option this game overrides would be
            # invisible here; the edit is meant to apply, so drop the override
            self.over.remove_option(section, key)

    def is_overridden(self, section, key):
        return self.over.has_option(section, key)

    def has_overrides(self):
        return any(self.over.items(sec) for sec in self.over.sections())

    def clear_overrides(self):
        for sec in list(self.over.sections()):
            self.over.remove_section(sec)

    def save(self):
        save_cfg(self.base)
        path = game_cfg_path(self.game)
        if self.has_overrides():
            os.makedirs(GAME_CFG_DIR, exist_ok=True)
            with open(path, "w") as f:
                self.over.write(f)
        elif os.path.exists(path):
            os.remove(path)

    def __getattr__(self, name):            # anything else: the global cfg
        return getattr(self.base, name)


def effective_cfg(game, base=None):
    return GameCfg(base if base is not None else load_cfg(),
                   load_game_overrides(game), game)


# The undo list is journaled before a game's overrides go into emu.cfg: a
# crash or power cut mid-game would otherwise leave that game's settings as
# everyone's. The next start replays a journal it finds.
OVERRIDE_JOURNAL = os.path.join(SYSTEM_DIR, "dreamster-restore.json")

# ---- per-game VMU --------------------------------------------------------------
# minicast always opens minicast/vmu_save_A1.bin (port A, first slot). With
# per-game VMUs the launcher swaps each game's own image in for the game's
# length and back out afterwards, the shared one parked meanwhile. The files
# live where MiSTer keeps saves and GameSync looks for them:
# saves/Dreamcast/<game>.sav - a bare 128 KB VMU image named like the .gdi
# (GameSync's MiSTer client writes downloaded saves as <game>.sav; its server
# keys Dreamcast saves by disc serial via the game name). A marker makes a
# crash or power cut recoverable: the next start copies the live image back
# to its game first. Only A1 is per game - other slots stay shared.
DC_SAVES_DIR = "/media/fat/saves/Dreamcast"
VMU_LIVE = os.path.join(MINICAST_DIR, "vmu_save_A1.bin")
VMU_SHARED = os.path.join(MINICAST_DIR, "vmu_save_A1.shared.bin")
VMU_MARKER = os.path.join(SYSTEM_DIR, "dreamster-vmu.json")


def _copy_synced(src, dst):
    tmp = dst + ".tmp"
    shutil.copyfile(src, tmp)
    with open(tmp, "rb+") as f:
        os.fsync(f.fileno())
    os.replace(tmp, dst)


def vmu_game_path(game):
    stem = os.path.basename(game).rsplit(".", 1)[0]
    return os.path.join(DC_SAVES_DIR, stem + ".sav")


def vmu_swap_out():
    """Game's image back to its save file, shared image back in place."""
    if not os.path.exists(VMU_MARKER):
        return
    try:
        import json
        with open(VMU_MARKER) as f:
            target = json.load(f).get("target")
    except (OSError, ValueError):
        target = None
    try:
        if target and os.path.exists(VMU_LIVE):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            _copy_synced(VMU_LIVE, target)
            crt_log("vmu saved to %s" % target)
        if os.path.exists(VMU_SHARED):
            os.replace(VMU_SHARED, VMU_LIVE)
        os.remove(VMU_MARKER)
    except OSError as e:
        crt_log("vmu swap-out failed: %s" % e)


def vmu_swap_in(game):
    """Put the game's own VMU image where minicast opens it."""
    vmu_swap_out()                    # a crashed previous game first
    target = vmu_game_path(game)
    try:
        import json
        if not os.path.exists(VMU_SHARED) and os.path.exists(VMU_LIVE):
            os.replace(VMU_LIVE, VMU_SHARED)
        if os.path.exists(target):
            _copy_synced(target, VMU_LIVE)
            how = "loaded"
        elif os.path.exists(VMU_SHARED):
            # first run of this game: start from the shared VMU so nothing
            # saved so far is lost
            _copy_synced(VMU_SHARED, VMU_LIVE)
            how = "new, seeded from the shared VMU"
        else:
            how = "new, blank"      # minicast formats a missing image
        _write_file_synced(VMU_MARKER, json.dumps({"target": target}))
        crt_log("vmu %s: %s" % (how, target))
    except OSError as e:
        crt_log("vmu swap-in failed (shared VMU in use): %s" % e)



def _write_file_synced(path, text):
    with open(path, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())


def _apply_overrides(over):
    """Lay a game's overrides over emu.cfg; returns what to restore."""
    if not any(over.items(sec) for sec in over.sections()):
        return []
    c = load_cfg()
    undo = []
    for sec in over.sections():
        for key, value in over.items(sec):
            had = c.has_option(sec, key)
            undo.append((sec, key, c.get(sec, key) if had else None))
            if not c.has_section(sec):
                c.add_section(sec)
            c.set(sec, key, value)
    try:
        import json
        _write_file_synced(OVERRIDE_JOURNAL, json.dumps(undo))
    except OSError as e:
        crt_log("override journal not written: %s" % e)
    save_cfg(c)
    return undo


def _restore_overrides(undo):
    if not undo:
        return
    c = load_cfg()
    for sec, key, value in undo:
        if value is None:
            if c.has_section(sec):
                c.remove_option(sec, key)
        else:
            if not c.has_section(sec):
                c.add_section(sec)
            c.set(sec, key, value)
    save_cfg(c)
    try:
        os.remove(OVERRIDE_JOURNAL)
    except OSError:
        pass


def recover_overrides():
    """Put back the global settings a crashed run left overridden."""
    if not os.path.exists(OVERRIDE_JOURNAL):
        return
    try:
        import json
        with open(OVERRIDE_JOURNAL) as f:
            undo = [tuple(u) for u in json.load(f)]
    except (OSError, ValueError):
        undo = []
    crt_log("previous run did not finish: restoring %d global setting(s)" % len(undo))
    if undo:
        _restore_overrides(undo)
    else:
        try:
            os.remove(OVERRIDE_JOURNAL)
        except OSError:
            pass


def save_cfg(cfg):
    if isinstance(cfg, GameCfg):
        cfg.save()
        return
    try:
        with open(CFG_PATH, "w") as f:
            cfg.write(f)
    except OSError:
        pass


# ----------------------------------------------------------------- games ---

def _existing_absolute_dirs(paths):
    directories = []
    seen = set()
    for path in paths:
        path = os.path.normpath(path.strip())
        if (not path or not os.path.isabs(path) or path in seen or
                not os.path.isdir(path)):
            continue
        seen.add(path)
        directories.append(path)
    return directories


def _configured_game_dirs(cfg):
    content_paths = ""
    if cfg.has_section("config"):
        content_paths = cfg.get(
            "config", "Dreamcast.ContentPath", fallback="")
    return _existing_absolute_dirs(content_paths.split(";"))


def _first_external_game_dir(usb_glob=USB_GAME_DIR_GLOB):
    external = _existing_absolute_dirs(sorted(glob.glob(usb_glob)))
    return external[0] if external else None


def resolve_game_dirs(cfg, system_dir=SYSTEM_DIR,
                      usb_glob=USB_GAME_DIR_GLOB):
    """Returns the configured game roots, else every USB/NVMe games/Dreamcast
    plus the microSD one - like MiSTer cores, games on either show up (the
    stock rule used only the first USB drive and hid the microSD games)."""
    configured = _configured_game_dirs(cfg)
    if configured:
        return configured

    dirs = _existing_absolute_dirs(sorted(glob.glob(usb_glob)))
    sd = os.path.normpath(system_dir)
    if sd not in dirs:
        dirs.append(sd)
    return dirs


def should_wait_for_external(cfg, game_dirs, games,
                             system_dir=SYSTEM_DIR):
    # right after boot a USB drive may not be mounted yet: wait for it (the
    # wait is bounded by the boot-time window) even if the microSD has games
    return (not _configured_game_dirs(cfg) and
            game_dirs == [os.path.normpath(system_dir)])


def startup_storage_wait_seconds(
        uptime_path="/proc/uptime",
        ready_at=STARTUP_STORAGE_READY_AT):
    try:
        with open(uptime_path, "r", encoding="ascii") as uptime_file:
            uptime = float(uptime_file.read().split()[0])
    except (OSError, ValueError, IndexError):
        return 0.0
    return max(0.0, ready_at - uptime)


def wait_for_external_game_dir(
        timeout, usb_glob=USB_GAME_DIR_GLOB,
        poll_interval=STORAGE_POLL_INTERVAL,
        clock_func=time.monotonic, sleep_func=time.sleep):
    if timeout <= 0:
        return None

    deadline = clock_func() + timeout
    while True:
        external = _first_external_game_dir(usb_glob)
        if external:
            return external
        remaining = deadline - clock_func()
        if remaining <= 0:
            return None
        sleep_func(min(poll_interval, remaining))


def display_names(games):
    """List names for scan_games() entries: no extension, and no folder
    when it only repeats the file name ('Crazy Taxi (USA)/Crazy Taxi
    (USA).gdi' -> 'Crazy Taxi (USA)'). Names that would then collide keep
    their full relative path."""
    names = []
    for label, _ in games:
        stem = label
        base = os.path.basename(label)
        if "." in base:
            stem = label[:len(label) - len(base)] + base.rsplit(".", 1)[0]
        d, b = os.path.split(stem)
        if d and b.startswith(os.path.basename(d)):
            stem = os.path.join(os.path.dirname(d), b)
        names.append(stem)
    counts = {}
    for n in names:
        counts[n] = counts.get(n, 0) + 1
    return [n if counts[n] == 1 else label
            for n, (label, _) in zip(names, games)]


def scan_games(game_dirs):
    games = []
    seen = set()
    for game_dir in game_dirs:
        game_dir = os.path.normpath(game_dir)
        for root, dirs, files in os.walk(game_dir):
            dirs.sort()
            for name in sorted(files):
                if not name.lower().endswith(GAME_EXTS):
                    continue
                path = os.path.abspath(os.path.join(root, name))
                path_key = os.path.normcase(os.path.realpath(path))
                if path_key in seen:
                    continue
                seen.add(path_key)
                games.append((os.path.relpath(path, game_dir), path))
    games.sort(key=lambda game: (game[0].lower(), game[1].lower()))
    return games


# ---------------------------------------------------------- input mapper ---
# evdev access is stdlib-only (raw ioctls); works on 32-bit ARM MiSTer.

CAPTURE_SECONDS = 5

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03

EVENT_FMT = "llHHi"  # struct input_event (native long timeval)
EVENT_SIZE = struct.calcsize(EVENT_FMT)


def _ioc_read(nr, size):
    return (2 << 30) | (size << 16) | (ord("E") << 8) | nr


EVIOCGID = _ioc_read(0x02, 8)


def EVIOCGNAME(length):
    return _ioc_read(0x06, length)


def EVIOCGUNIQ(length):
    return _ioc_read(0x08, length)


def EVIOCGBIT(ev, length):
    return _ioc_read(0x20 + ev, length)


def EVIOCGABS(code):
    return _ioc_read(0x40 + code, 24)


def test_bit(buf, bit):
    return bool(buf[bit // 8] >> (bit % 8) & 1)


KEY_NAMES = {}
for _i, _c in enumerate("1234567890"):
    KEY_NAMES[2 + _i] = "KEY_" + _c
for _i, _c in enumerate("QWERTYUIOP"):
    KEY_NAMES[16 + _i] = "KEY_" + _c
for _i, _c in enumerate("ASDFGHJKL"):
    KEY_NAMES[30 + _i] = "KEY_" + _c
for _i, _c in enumerate("ZXCVBNM"):
    KEY_NAMES[44 + _i] = "KEY_" + _c
for _i in range(10):
    KEY_NAMES[59 + _i] = "KEY_F%d" % (_i + 1)
KEY_NAMES.update({
    1: "KEY_ESC", 14: "KEY_BACKSPACE", 15: "KEY_TAB", 28: "KEY_ENTER",
    29: "KEY_LEFTCTRL", 42: "KEY_LEFTSHIFT", 54: "KEY_RIGHTSHIFT",
    56: "KEY_LEFTALT", 57: "KEY_SPACE", 58: "KEY_CAPSLOCK",
    97: "KEY_RIGHTCTRL", 100: "KEY_RIGHTALT",
    102: "KEY_HOME", 103: "KEY_UP", 104: "KEY_PAGEUP", 105: "KEY_LEFT",
    106: "KEY_RIGHT", 107: "KEY_END", 108: "KEY_DOWN", 109: "KEY_PAGEDOWN",
    110: "KEY_INSERT", 111: "KEY_DELETE",
    0x110: "BTN_LEFT", 0x111: "BTN_RIGHT", 0x112: "BTN_MIDDLE",
    0x113: "BTN_SIDE", 0x114: "BTN_EXTRA",
    0x120: "BTN_TRIGGER", 0x121: "BTN_THUMB", 0x122: "BTN_THUMB2",
    0x123: "BTN_TOP", 0x124: "BTN_TOP2", 0x125: "BTN_PINKIE",
    0x126: "BTN_BASE", 0x127: "BTN_BASE2", 0x128: "BTN_BASE3",
    0x129: "BTN_BASE4", 0x12a: "BTN_BASE5", 0x12b: "BTN_BASE6",
    0x130: "BTN_SOUTH(A)", 0x131: "BTN_EAST(B)", 0x133: "BTN_NORTH(X)",
    0x134: "BTN_WEST(Y)", 0x135: "BTN_Z", 0x136: "BTN_TL", 0x137: "BTN_TR",
    0x138: "BTN_TL2", 0x139: "BTN_TR2", 0x13a: "BTN_SELECT",
    0x13b: "BTN_START", 0x13c: "BTN_MODE", 0x13d: "BTN_THUMBL",
    0x13e: "BTN_THUMBR",
    0x220: "BTN_DPAD_UP", 0x221: "BTN_DPAD_DOWN", 0x222: "BTN_DPAD_LEFT",
    0x223: "BTN_DPAD_RIGHT",
})

ABS_NAMES = {
    0: "ABS_X", 1: "ABS_Y", 2: "ABS_Z", 3: "ABS_RX", 4: "ABS_RY",
    5: "ABS_RZ", 6: "ABS_THROTTLE", 7: "ABS_RUDDER", 8: "ABS_WHEEL",
    9: "ABS_GAS", 10: "ABS_BRAKE",
    16: "ABS_HAT0X", 17: "ABS_HAT0Y", 18: "ABS_HAT1X", 19: "ABS_HAT1Y",
    20: "ABS_HAT2X", 21: "ABS_HAT2Y", 22: "ABS_HAT3X", 23: "ABS_HAT3Y",
}

REL_NAMES = {
    0: "REL_X", 1: "REL_Y", 2: "REL_Z", 6: "REL_HWHEEL", 7: "REL_DIAL",
    8: "REL_WHEEL", 11: "REL_WHEEL_HI_RES", 12: "REL_HWHEEL_HI_RES",
}


def key_name(code):
    return KEY_NAMES.get(code, "KEY_%d" % code)


def abs_name(code):
    return ABS_NAMES.get(code, "ABS_%d" % code)


def rel_name(code):
    return REL_NAMES.get(code, "REL_%d" % code)


class Device:
    def __init__(self, path):
        self.path = path
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            raw = fcntl.ioctl(fd, EVIOCGNAME(256), b"\0" * 256)
            self.name = raw.split(b"\0", 1)[0].decode(errors="replace") or "?"

            bus, vid, pid, ver = struct.unpack(
                "HHHH", fcntl.ioctl(fd, EVIOCGID, b"\0" * 8))
            self.id = "%04x:%04x:%04x:%04x" % (bus, vid, pid, ver)
            try:
                raw = fcntl.ioctl(fd, EVIOCGUNIQ(64), b"\0" * 64)
                uniq = raw.split(b"\0", 1)[0].decode(errors="replace")
                if uniq:
                    self.id += ":" + uniq
            except OSError:
                pass

            ev = fcntl.ioctl(fd, EVIOCGBIT(0, 8), b"\0" * 8)
            self.has_key = test_bit(ev, EV_KEY)
            self.has_rel = test_bit(ev, EV_REL)
            self.has_abs = test_bit(ev, EV_ABS)

            self.abs_codes = []
            if self.has_abs:
                bits = fcntl.ioctl(fd, EVIOCGBIT(EV_ABS, 8), b"\0" * 8)
                self.abs_codes = [c for c in range(64) if test_bit(bits, c)]

            keybits = b""
            if self.has_key:
                keybits = fcntl.ioctl(fd, EVIOCGBIT(EV_KEY, 96), b"\0" * 96)

            if self.has_abs and keybits and (test_bit(keybits, 0x130)
                                             or test_bit(keybits, 0x120)):
                self.kind = "gamepad"
            elif self.has_rel or (keybits and (test_bit(keybits, 0x110)
                                               or test_bit(keybits, 0x14a))):
                # relative mice, or absolute pointers (BTN_LEFT/BTN_TOUCH):
                # tablets, touchpads, KVM-style absolute mice
                self.kind = "mouse"
            elif keybits and test_bit(keybits, 30):  # KEY_A
                self.kind = "keyboard"
            else:
                self.kind = "other"
        finally:
            os.close(fd)


# Sensor side-nodes of modern pads (DualSense / DualShock 4 "Motion Sensors",
# "Touchpad", ...) are not controls and flood events - a DualSense's motion
# node sends ~1000/s. Read alongside the pad they delay its real presses (a
# release landing after the auto-repeat delay makes the cursor jump rows), so
# they are left out entirely, as GameSync does.
NOISY_NAME_PARTS = ("motion sensor", "touchpad", "accelerometer", "gyro")


def _noisy_node(name):
    n = name.lower()
    return any(part in n for part in NOISY_NAME_PARTS)


def scan_devices():
    devs = []
    paths = sorted(glob.glob("/dev/input/event*"),
                   key=lambda p: int("".join(filter(str.isdigit, p)) or "0"))
    seen = {}
    for path in paths:
        try:
            dev = Device(path)
        except OSError:
            continue
        n = seen.get(dev.id, 0)
        seen[dev.id] = n + 1
        if n:  # two identical devices with no unique id
            dev.id += "#%d" % (n + 1)
        # numbered first, so ids match minicast's, which sees every node
        if _noisy_node(dev.name):
            continue
        devs.append(dev)
    return devs


def read_absinfo(fd, code):
    """Returns (value, min, max, fuzz, flat, resolution)."""
    raw = fcntl.ioctl(fd, EVIOCGABS(code), b"\0" * 24)
    return struct.unpack("6i", raw)


def read_events(fd):
    """Returns list of (type, code, value), or None if the device is gone.
    Drains everything queued (bounded): reading a fixed slice per poll let a
    pad's stick jitter queue up in front of its button/dpad events."""
    chunks = []
    for _ in range(64):
        try:
            chunk = os.read(fd, EVENT_SIZE * 256)
        except (BlockingIOError, InterruptedError):
            break
        except OSError:
            if not chunks:
                return None
            break
        if not chunk:
            break
        chunks.append(chunk)
        if len(chunk) < EVENT_SIZE * 256:
            break
    data = b"".join(chunks)
    out = []
    for off in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
        _, _, etype, code, value = struct.unpack_from(EVENT_FMT, data, off)
        out.append((etype, code, value))
    return out


def drain(fd):
    while True:
        try:
            if not os.read(fd, 4096):
                return
        except OSError:
            return


# device id -> {target key -> mapping dict}. A device with no entry uses
# the per-kind defaults below; an explicit empty dict (after "Remove
# configuration") means inactive. Persisted in emu.cfg [input0]..[inputN].
CONFIG = {}
# device id -> maple port 0..3 (A..D); missing = 0/A. Persisted as `Port`
# in the device's [inputN] section; minicast routes the device's state to
# kcode[port] etc.
PORTS = {}
PORT_NAMES = ("Port A", "Port B", "Port C", "Port D")


def device_port(dev_id):
    return PORTS.get(dev_id, 0)

TARGETS = [
    ("dpad_up", "Dpad Up"),
    ("dpad_down", "Dpad Down"),
    ("dpad_left", "Dpad Left"),
    ("dpad_right", "Dpad Right"),
    ("btn_a", "Button A"),
    ("btn_b", "Button B"),
    ("btn_x", "Button X"),
    ("btn_y", "Button Y"),
    ("btn_start", "Button Start"),
    ("btn_exit", "Exit Emulator"),
    ("btn_screenshot", "Screenshot"),
    ("analog_x", "Analog X  (-127..127)"),
    ("analog_y", "Analog Y  (-127..127)"),
    ("trig_l", "Trigger Left  (0..255)"),
    ("trig_r", "Trigger Right (0..255)"),
]

# capture prompts name the direction to actuate. For the analog axes the
# prompted direction is the NEGATIVE end of the DC axis (left/up negative),
# so an axis capture flips the detected sign to point the mapping there and
# a key capture becomes the negative keypair half (positive asked second).
CAPTURE_PROMPTS = {
    "dpad_up": "Move Up",
    "dpad_down": "Move Down",
    "dpad_left": "Move Left",
    "dpad_right": "Move Right",
    "analog_x": "Move Left",
    "analog_y": "Move Up",
}
ANALOG_POS_PROMPTS = {"analog_x": "Move Right", "analog_y": "Move Down"}

# emu.cfg key per target, in file order
TARGET_CFG_KEYS = [
    ("dpad_up", "DpadUp"),
    ("dpad_down", "DpadDown"),
    ("dpad_left", "DpadLeft"),
    ("dpad_right", "DpadRight"),
    ("btn_a", "ButtonA"),
    ("btn_b", "ButtonB"),
    ("btn_x", "ButtonX"),
    ("btn_y", "ButtonY"),
    ("btn_start", "ButtonStart"),
    ("btn_exit", "ButtonExit"),
    ("btn_screenshot", "ButtonScreenshot"),
    ("analog_x", "AxisX"),
    ("analog_y", "AxisY"),
    ("trig_l", "TriggerL"),
    ("trig_r", "TriggerR"),
]


def _key(code):
    return {"kind": "key", "code": code}


def _abs(code, direction):
    return {"kind": "abs", "code": code, "dir": direction}


def _rel(code, direction):
    return {"kind": "rel", "code": code, "dir": direction}


# Defaults follow minicast/main.cpp: js0 buttons 0/1/2/3 + start 10 and
# axes 0/1 (stick), 2/5 (triggers), 6/7 (dpad) translated to evdev codes;
# keyboard uses the (commented-out) kbhit() map. Mice: motion -> analog,
# left/right click -> A/B.
DEFAULTS = {
    "gamepad": {
        "dpad_up": _abs(17, -1),     # ABS_HAT0Y
        "dpad_down": _abs(17, 1),
        "dpad_left": _abs(16, -1),   # ABS_HAT0X
        "dpad_right": _abs(16, 1),
        "btn_a": _key(0x130),        # BTN_SOUTH
        "btn_b": _key(0x131),        # BTN_EAST
        "btn_x": _key(0x133),        # BTN_NORTH
        "btn_y": _key(0x134),        # BTN_WEST
        "btn_start": _key(0x13b),    # BTN_START
        "analog_x": _abs(0, 1),      # ABS_X
        "analog_y": _abs(1, 1),      # ABS_Y
        "trig_l": _abs(2, 1),        # ABS_Z
        "trig_r": _abs(5, 1),        # ABS_RZ
    },
    "keyboard": {
        "dpad_up": _key(23),         # I
        "dpad_down": _key(37),       # K
        "dpad_left": _key(36),       # J
        "dpad_right": _key(38),      # L
        "btn_a": _key(30),           # A
        "btn_b": _key(45),           # X
        "btn_x": _key(46),           # C
        "btn_y": _key(47),           # V
        "btn_start": _key(31),       # S
        "analog_x": {"kind": "keypair", "neg": 33, "pos": 35},  # F / H
        "analog_y": {"kind": "keypair", "neg": 20, "pos": 34},  # T / G
        "trig_l": _key(18),          # E
        "trig_r": _key(19),          # R
    },
    "mouse": {
        "analog_x": _rel(0, 1),      # REL_X
        "analog_y": _rel(1, 1),      # REL_Y
        "btn_a": _key(0x110),        # BTN_LEFT
        "btn_b": _key(0x111),        # BTN_RIGHT
    },
}


def default_config(dev):
    return DEFAULTS.get(dev.kind, {})


def effective_config(dev):
    if dev.id in CONFIG:
        return CONFIG[dev.id]
    return default_config(dev)


def mapping_text(m):
    if m is None:
        return "-"
    if m["kind"] == "key":
        return key_name(m["code"])
    if m["kind"] == "keypair":
        neg = key_name(m["neg"]) if m["neg"] is not None else "-"
        pos = key_name(m["pos"]) if m["pos"] is not None else "-"
        return "%s / %s" % (neg, pos)
    if m["kind"] == "abs":
        return "%s %s" % (abs_name(m["code"]), "+" if m["dir"] > 0 else "-")
    return "%s %s" % (rel_name(m["code"]), "+" if m["dir"] > 0 else "-")


# Map values are colon-separated for easy C++ parsing:
#   key:<code>              button/key press
#   keys:<neg>:<pos>        key pair driving an axis (-1 = unset)
#   abs:<code>:<dir>        absolute axis, dir 1 or -1
#   rel:<code>:<dir>        relative axis (mouse motion)

def encode_mapping(m):
    if m["kind"] == "key":
        return "key:%d" % m["code"]
    if m["kind"] == "keypair":
        return "keys:%d:%d" % (m["neg"] if m["neg"] is not None else -1,
                               m["pos"] if m["pos"] is not None else -1)
    if m["kind"] == "abs":
        return "abs:%d:%d" % (m["code"], m["dir"])
    return "rel:%d:%d" % (m["code"], m["dir"])


def decode_mapping(text):
    parts = text.strip().split(":")
    try:
        if parts[0] == "key" and len(parts) == 2:
            return {"kind": "key", "code": int(parts[1])}
        if parts[0] == "keys" and len(parts) == 3:
            neg, pos = int(parts[1]), int(parts[2])
            return {"kind": "keypair",
                    "neg": neg if neg >= 0 else None,
                    "pos": pos if pos >= 0 else None}
        if parts[0] == "abs" and len(parts) == 3:
            return {"kind": "abs", "code": int(parts[1]),
                    "dir": 1 if int(parts[2]) >= 0 else -1}
        if parts[0] == "rel" and len(parts) == 3:
            return {"kind": "rel", "code": int(parts[1]),
                    "dir": 1 if int(parts[2]) >= 0 else -1}
    except ValueError:
        pass
    return None


def load_input_config(cfg):
    """Populates CONFIG from the shared emu.cfg parser."""
    for section in cfg.sections():
        if not re.match(r"input\d+$", section):
            continue
        dev_id = cfg.get(section, "DeviceId", fallback="")
        if not dev_id:
            continue
        mappings = {}
        for target, cfg_key in TARGET_CFG_KEYS:
            val = cfg.get(section, cfg_key, fallback=None)
            if val:
                m = decode_mapping(val)
                if m is not None:
                    mappings[target] = m
        # a DeviceId-only section is an explicitly cleared device
        CONFIG[dev_id] = mappings
        try:
            port = int(cfg.get(section, "Port", fallback="0"))
        except ValueError:
            port = 0
        PORTS[dev_id] = port if 0 <= port <= 3 else 0


def save_input_config(cfg, devices):
    """Rewrites [input0]..[inputN] in the shared emu.cfg parser and saves.
    Returns the number of device sections written."""
    # materialize defaults for connected devices so the C++ side only
    # ever needs emu.cfg
    for dev in devices:
        if dev.id not in CONFIG:
            defaults = default_config(dev)
            if defaults:
                CONFIG[dev.id] = dict(defaults)

    for section in list(cfg.sections()):
        if re.match(r"input\d+$", section):
            cfg.remove_section(section)
    n = 0
    for dev_id, mappings in CONFIG.items():
        section = "input%d" % n
        cfg.add_section(section)
        cfg.set(section, "DeviceId", dev_id)
        cfg.set(section, "Port", str(device_port(dev_id)))
        for target, cfg_key in TARGET_CFG_KEYS:
            m = mappings.get(target)
            if m is not None:
                cfg.set(section, cfg_key, encode_mapping(m))
        n += 1
    # NOTE: what maple device sits on each port is owned by the Dreamcast
    # Peripherals page ([input] deviceN); mapping a device to a port does
    # not force a controller onto that bus.
    save_cfg(cfg)
    return n


class InputDetector:
    """Reports the first significant input (ignoring axis deadzone noise)."""

    REL_THRESH = {0: 15, 1: 15}  # REL_X/REL_Y need real motion; wheels: 1

    def __init__(self, fd, dev):
        self.fd = fd
        self.abs_info = {}
        self.abs_base = {}
        for code in dev.abs_codes:
            try:
                info = read_absinfo(fd, code)
            except OSError:
                continue
            self.abs_info[code] = info
            self.abs_base[code] = info[0]
        self.rel_accum = {}

    def check(self, etype, code, value):
        """Returns a mapping dict once a significant input is seen."""
        if etype == EV_KEY and value == 1:
            return {"kind": "key", "code": code}
        if etype == EV_ABS:
            info = self.abs_info.get(code)
            if info is None:
                try:
                    info = read_absinfo(self.fd, code)
                except OSError:
                    return None
                self.abs_info[code] = info
                self.abs_base[code] = info[0]
            delta = value - self.abs_base[code]
            thresh = max(1, (info[2] - info[1]) * 0.2)
            if abs(delta) >= thresh:
                return {"kind": "abs", "code": code,
                        "dir": 1 if delta > 0 else -1,
                        "min": info[1], "max": info[2]}
        if etype == EV_REL:
            acc = self.rel_accum.get(code, 0) + value
            self.rel_accum[code] = acc
            if abs(acc) >= self.REL_THRESH.get(code, 1):
                return {"kind": "rel", "code": code,
                        "dir": 1 if acc > 0 else -1}
        return None


def capture_mapping(scr, dev, render, prompt="Waiting"):
    """Waits up to CAPTURE_SECONDS for input on dev; returns mapping or None.

    render(text) redraws the screen with the countdown on the selected row.
    """
    try:
        fd = os.open(dev.path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        render("[error: cannot open device]")
        scr.refresh()
        time.sleep(1.0)
        return None
    try:
        drain(fd)
        det = InputDetector(fd, dev)
        scr.nodelay(True)
        deadline = time.monotonic() + CAPTURE_SECONDS
        while True:
            now = time.monotonic()
            if now >= deadline:
                return None
            remaining = int(deadline - now) + 1  # CAPTURE_SECONDS .. 1
            text = "[" + prompt + " ... " + "...".join(
                str(n) for n in range(CAPTURE_SECONDS, remaining - 1, -1)) + "]"
            render(text)
            scr.refresh()
            scr.getch()   # drain tty so captured keys don't leak into menus
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            evs = read_events(fd)
            if evs is None:
                return None
            for etype, code, value in evs:
                m = det.check(etype, code, value)
                if m:
                    return m
    finally:
        scr.nodelay(False)
        os.close(fd)


class DCState:
    """Applies a device's mappings to its events -> Dreamcast pad state."""

    REL_GAIN = 4.0        # mouse counts -> analog deflection

    def __init__(self, dev, fd):
        self.dev = dev
        self.cfg = effective_config(dev)
        self.absrange = {}
        for code in dev.abs_codes:
            try:
                info = read_absinfo(fd, code)
                self.absrange[code] = (info[1], info[2])
            except OSError:
                pass
        self.buttons = set()  # dpad_*/btn_* targets currently held
        self.analog = {"analog_x": 0, "analog_y": 0}
        self.trig = {"trig_l": 0, "trig_r": 0}
        self.kp = {}          # keypair target -> [neg held, pos held]
        self.rel_accum = {}   # rel-driven analog target -> float
        self.by_key = {}
        self.by_abs = {}
        self.by_rel = {}
        for target, m in self.cfg.items():
            if m["kind"] == "key":
                self.by_key.setdefault(m["code"], []).append((target, None))
            elif m["kind"] == "keypair":
                if m["neg"] is not None:
                    self.by_key.setdefault(m["neg"], []).append((target, 0))
                if m["pos"] is not None:
                    self.by_key.setdefault(m["pos"], []).append((target, 1))
            elif m["kind"] == "abs":
                self.by_abs.setdefault(m["code"], []).append((target, m))
            elif m["kind"] == "rel":
                self.by_rel.setdefault(m["code"], []).append((target, m))
                self.rel_accum[target] = 0.0

    def feed(self, etype, code, value):
        if etype == EV_KEY:
            for target, side in self.by_key.get(code, []):
                if side is not None:  # keypair half driving an analog axis
                    st = self.kp.setdefault(target, [False, False])
                    st[side] = bool(value)
                    self.analog[target] = (-128 if st[0] else
                                           (127 if st[1] else 0))
                elif target in self.trig:
                    self.trig[target] = 255 if value else 0
                else:
                    if value:
                        self.buttons.add(target)
                    else:
                        self.buttons.discard(target)
        elif etype == EV_ABS:
            for target, m in self.by_abs.get(code, []):
                lo, hi = m.get("min"), m.get("max")
                if lo is None or hi is None or hi <= lo:
                    lo, hi = self.absrange.get(code, (-32768, 32767))
                if hi <= lo:
                    continue
                norm = (value - lo) / float(hi - lo) * 2.0 - 1.0  # -1..1
                if m["dir"] < 0:
                    norm = -norm
                if target in self.analog:
                    self.analog[target] = max(-127, min(127,
                                                        int(round(norm * 127))))
                elif target in self.trig:
                    self.trig[target] = max(0, min(255,
                                                   int(round((norm + 1)
                                                             / 2 * 255))))
                elif norm > 0.5:
                    self.buttons.add(target)
                else:
                    self.buttons.discard(target)
        elif etype == EV_REL:
            for target, m in self.by_rel.get(code, []):
                if target in self.analog:
                    self.rel_accum[target] += value * m["dir"] * self.REL_GAIN

    def tick(self):
        # mouse deflection decays back to center when motion stops
        for target in self.rel_accum:
            acc = self.rel_accum[target]
            self.analog[target] = max(-127, min(127, int(acc)))
            self.rel_accum[target] = acc * 0.8 if abs(acc) >= 1.0 else 0.0


# --------------------------------------------------------- evdev menu nav ---
# Menu navigation from configured evdev devices: the mapped dpad moves the
# cursor, A confirms (ENTER). Keyboard-kind devices are
# deliberately NOT read here: their input already arrives through the
# terminal (console tty locally, pty over ssh), so reading them from evdev
# too would process every key twice. Gamepads/mice produce no tty input, so
# evdev is their only path - no double handling either way, and no exclusive
# grabs needed (MiSTer, the other evdev reader, is killed on script entry).

NAV_KEYS = {
    "dpad_up": curses.KEY_UP,
    "dpad_down": curses.KEY_DOWN,
    "dpad_left": curses.KEY_LEFT,
    "dpad_right": curses.KEY_RIGHT,
    "btn_a": 10,        # confirm / enter
}
NAV_REPEAT = ("dpad_up", "dpad_down", "dpad_left", "dpad_right")
NAV_REPEAT_DELAY = 0.40
NAV_REPEAT_RATE = 0.11


class NavPump:
    """Translates mapped dpad/A/B presses on non-keyboard evdevs into keys."""

    def __init__(self):
        self.states = {}  # fd -> DCState
        self.nodes = {}   # fd -> (path, inode) it was opened from
        self.queue = []   # pending key codes
        self.held = {}    # (fd, target) -> next auto-repeat time
        self.dir_mtime = None
        self._open_new()

    def _open_new(self):
        """Opens every nav-capable device not open yet. Pads come and go at
        any time - a USB DualSense re-enumerating a few seconds after start
        left the menu with a dead handle and no pad - so this reruns whenever
        /dev/input changes."""
        try:
            self.dir_mtime = os.stat("/dev/input").st_mtime
        except OSError:
            self.dir_mtime = None
        have = set(self.nodes.values())
        for dev in scan_devices():
            if dev.kind == "keyboard":
                continue
            if not any(t in effective_config(dev) for t in NAV_KEYS):
                continue
            try:
                ino = os.stat(dev.path).st_ino
            except OSError:
                continue
            if (dev.path, ino) in have:
                continue
            try:
                fd = os.open(dev.path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            drain(fd)
            self.states[fd] = DCState(dev, fd)
            self.nodes[fd] = (dev.path, ino)
            nav_dbg("nav device fd%d %s %r" % (fd, dev.path, dev.name))

    def _drop(self, fd):
        nav_dbg("nav device fd%d gone" % fd)
        try:
            os.close(fd)
        except OSError:
            pass
        self.states.pop(fd, None)
        self.nodes.pop(fd, None)
        for key in [k for k in self.held if k[0] == fd]:
            del self.held[key]

    def close(self):
        for fd in self.states:
            os.close(fd)
        self.states = {}
        self.nodes = {}
        self.queue = []
        self.held = {}

    def fds(self):
        return list(self.states)

    def pump(self):
        now = time.monotonic()
        try:
            changed = os.stat("/dev/input").st_mtime != self.dir_mtime
        except OSError:
            changed = False
        if changed:
            # a replaced node (same path, new inode) means the old handle is
            # dead even if no read has failed on it yet
            for fd, (path, ino) in list(self.nodes.items()):
                try:
                    if os.stat(path).st_ino != ino:
                        self._drop(fd)
                except OSError:
                    self._drop(fd)
            self._open_new()
        for fd in list(self.states):
            st = self.states[fd]
            evs = read_events(fd)
            if evs is None:  # device unplugged
                self._drop(fd)
                continue
            if not evs:
                continue
            before = set(st.buttons)
            for etype, code, value in evs:
                st.feed(etype, code, value)
                if etype in (EV_KEY, EV_ABS) and (etype == EV_KEY or code >= 16):
                    nav_dbg("  fd%d ev type=%d code=%d val=%d" % (fd, etype, code, value))
            for target in before - st.buttons:
                nav_dbg("fd%d release %s" % (fd, target))
            for target in st.buttons - before:
                if target in NAV_KEYS:
                    nav_dbg("fd%d press %s -> key %d" % (fd, target, NAV_KEYS[target]))
                    self.queue.append(NAV_KEYS[target])
                    if target in NAV_REPEAT:
                        self.held[(fd, target)] = now + NAV_REPEAT_DELAY
        for key in list(self.held):
            fd, target = key
            st = self.states.get(fd)
            if st is None or target not in st.buttons:
                del self.held[key]
            elif now >= self.held[key]:
                nav_dbg("fd%d repeat %s" % (fd, target))
                self.queue.append(NAV_KEYS[target])
                self.held[key] = now + NAV_REPEAT_RATE

    def next_key(self):
        self.pump()
        if self.queue:
            return self.queue.pop(0)
        return None

    def flush(self):
        """Discards pending nav input (after test/capture screens, where the
        same physical presses were consumed by a different reader)."""
        self.pump()
        self.queue = []
        self.held = {}


NAV = [None]  # active NavPump; rebuilt when mappings change

# Menu input trace: every key the menus receive, with its source (evdev node
# + raw event, auto-repeat, or the terminal). Truncated at each start.
NAV_DEBUG_LOG = os.path.join(MINICAST_DIR, "logs", "nav-debug.log")
_NAV_DBG = [None, 0.0]


def nav_dbg(msg):
    f = _NAV_DBG[0]
    if f is None:
        try:
            f = _NAV_DBG[0] = open(NAV_DEBUG_LOG, "w", buffering=1)
            _NAV_DBG[1] = time.monotonic()
        except OSError:
            return
    try:
        f.write("%9.3f %s\n" % (time.monotonic() - _NAV_DBG[1], msg))
    except OSError:
        pass


def nav_flush():
    if NAV[0] is not None:
        NAV[0].flush()


def nav_getch(scr):
    """Blocking scr.getch() that also accepts evdev navigation input."""
    nav = NAV[0]
    while True:
        if nav is not None:
            ch = nav.next_key()
            if ch is not None:
                return ch
        rl = [0] + (nav.fds() if nav else [])
        timeout = 0.05 if (nav and nav.held) else 1.0
        try:
            r, _, _ = select.select(rl, [], [], timeout)
        except OSError:
            r = []
        # 60ms window lets terminal escape sequences complete; a plain poll
        # (timeout 0) otherwise, which also harvests pending KEY_RESIZE
        scr.timeout(60 if 0 in r else 0)
        ch = scr.getch()
        scr.timeout(-1)
        if ch != -1:
            nav_dbg("tty key %d" % ch)
            return ch


def draw_tokens(scr, y, x, tokens):
    """tokens: (text, None=label / False=idle / True=pressed)."""
    for text, state in tokens:
        if state is None:
            safe_addstr(scr, y, x, text, color(C_DIM))
        elif state:
            safe_addstr(scr, y, x, text, color(C_SEL, curses.A_BOLD))
        else:
            safe_addstr(scr, y, x, text)
        x += len(text) + 1
    return x


def test_screen(scr, devices, subtitle):
    """Live view of the mapped Dreamcast pad state, per device."""
    fds = {}
    states = {}
    for dev in devices:
        try:
            fd = os.open(dev.path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        drain(fd)
        fds[fd] = dev
        states[fd] = DCState(dev, fd)
    scr.nodelay(True)
    top = 0
    # the only exits are the pinned Back entry (tty ENTER) or a fresh A
    # press on a device; armed per-device only after A is first seen
    # released, so the press that opened this screen can't exit it
    a_prev = {}  # fd -> btn_a held on the previous pump
    try:
        while True:
            ch = scr.getch()
            if ch in KEY_ENTER:
                return
            if ch == curses.KEY_UP:
                top -= 1
            elif ch == curses.KEY_DOWN:
                top += 1
            if fds:
                r, _, _ = select.select(list(fds), [], [], 0.05)
                for fd in r:
                    evs = read_events(fd)
                    if evs is None:
                        os.close(fd)
                        del states[fd]
                        del fds[fd]
                        a_prev.pop(fd, None)
                        continue
                    for etype, code, value in evs:
                        states[fd].feed(etype, code, value)
            else:
                time.sleep(0.05)
            for st in states.values():
                st.tick()

            for fd, st in states.items():
                a_now = "btn_a" in st.buttons
                if a_now and not a_prev.get(fd, True):
                    return
                a_prev[fd] = a_now

            draw_title(scr, subtitle)
            h, _ = scr.getmaxyx()
            draw_item(scr, 3, 4, "Back", True, bar=False)
            list_top = 5
            list_h = max(1, h - list_top - (1 if is_pixel(scr) else 2))
            total = sum(3 if not states[fd].cfg else 4 for fd in fds)
            top = max(0, min(top, max(0, total - list_h)))

            def put(yv, x, text, attr=0):
                y = list_top + yv - top
                if list_top <= y < list_top + list_h:
                    safe_addstr(scr, y, x, text, attr)

            yv = 0
            for fd, dev in list(fds.items()):
                st = states[fd]
                put(yv, 2, dev.name[:44], curses.A_BOLD)
                put(yv, 2 + min(44, len(dev.name)) + 2,
                    "[%s]" % dev.id, color(C_DIM))
                yv += 1
                if not st.cfg:
                    put(yv, 4, "(no mappings)", color(C_DIM))
                    yv += 2
                    continue
                y = list_top + yv - top
                if list_top <= y < list_top + list_h:
                    draw_tokens(scr, y, 4, [
                        ("Dpad:", None),
                        ("UP", "dpad_up" in st.buttons),
                        ("DOWN", "dpad_down" in st.buttons),
                        ("LEFT", "dpad_left" in st.buttons),
                        ("RIGHT", "dpad_right" in st.buttons),
                        ("  Buttons:", None),
                        ("A", "btn_a" in st.buttons),
                        ("B", "btn_b" in st.buttons),
                        ("X", "btn_x" in st.buttons),
                        ("Y", "btn_y" in st.buttons),
                        ("START", "btn_start" in st.buttons),
                    ])
                yv += 1
                put(yv, 4,
                    "Analog X:%+4d Y:%+4d    Trigger L:%3d R:%3d"
                    % (st.analog["analog_x"], st.analog["analog_y"],
                       st.trig["trig_l"], st.trig["trig_r"]),
                    color(C_VALUE))
                yv += 2
            draw_footer(scr, "Press buttons / move axes   Up/Down: scroll   "
                        "A/Enter: back")
            scr.refresh()
    finally:
        scr.nodelay(False)
        for fd in fds:
            os.close(fd)


def port_label(cfg, port):
    pid = get_port_peripheral(cfg, port)
    return "%s [%s]" % (PORT_NAMES[port],
                        PERIPHERAL_LABELS.get(pid, "Custom"))


def device_list_screen(scr, devices, cfg):
    """Returns ("test", None), ("open", dev), or None to exit."""
    rows = [("back", None),
            ("header", "General"),
            ("test", None),
            ("header", "Input Devices")]
    rows += [("dev", d) for d in devices]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0
    top = 0
    notice = ""
    notice_attr = 0
    while True:
        draw_title(scr, "%d input device(s)" % len(devices))
        h, w = scr.getmaxyx()
        list_top, list_h = list_geom(scr, 4, 3)
        px = is_pixel(scr)

        cur = selectable[sel]
        if cur < top:
            top = cur
        if cur >= top + list_h:
            top = cur - list_h + 1
        top = max(0, min(top, max(0, len(rows) - list_h)))

        for i in range(top, min(len(rows), top + list_h)):
            kind, payload = rows[i]
            y = list_top + (i - top)
            if kind == "header":
                draw_header(scr, y, payload)
                continue
            if kind == "back":
                text = "Back"
            elif kind == "test":
                text = "Test (all devices)"
            elif px:
                # name, then kind + port on the right; the id is on the
                # device's own page
                active = (PORT_NAMES[device_port(payload.id)]
                          if effective_config(payload) else "inactive")
                right = "%-8s %s" % (payload.kind, active)
                text = fit(payload.name, max(8, w - PX_ITEM_X - len(right) - 2))
                draw_value(scr, y, 0, right, i == cur,
                           attr=color(C_VALUE) if effective_config(payload)
                           else color(C_DIM))
            else:
                active = ("[Active: %s]" % PORT_NAMES[device_port(payload.id)]
                          if effective_config(payload) else "")
                text = "%-32s %-10s %s  %s" % (payload.name[:32],
                                               payload.kind,
                                               "[%s]" % payload.id, active)
            draw_item(scr, y, 4, text, i == cur)

        if notice:
            safe_addstr(scr, h - 2, 1, notice, notice_attr)
        draw_footer(scr, "Up/Down: select   A/Enter: open   "
                    "(changes save automatically)")
        scr.refresh()

        ch = nav_getch(scr)
        notice = ""
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER:
            kind, payload = rows[selectable[sel]]
            if kind == "back":
                return None
            return (kind, payload)


def device_screen(scr, dev, cfg, devices):
    # rows: ("back",), ("test",), ("header", text), ("map", key, label),
    #       ("remove",)
    # every mutation is saved to emu.cfg immediately (auto-save)
    rows = [("back",), ("header", "General"), ("test",), ("port",),
            ("header", "Mappings")]
    rows += [("map", key, label) for key, label in TARGETS]
    rows += [("header", "Danger Zone"), ("remove",)]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0
    top = 0

    def draw(capture_idx=None, capture_text=""):
        nonlocal top
        draw_title(scr, dev.name)
        h, w = scr.getmaxyx()
        ix = 0 if is_pixel(scr) else 2
        safe_addstr(scr, 3, ix, "ID:   %s" % dev.id, color(C_DIM))
        safe_addstr(scr, 4, ix, "Path: %s  (%s)" % (dev.path, dev.kind),
                    color(C_DIM))
        # (pixel: the list starts right under the two info lines)
        list_top, list_h = list_geom(scr, 6)
        cur = selectable[sel]
        if cur < top:
            top = cur
        if cur >= top + list_h:
            top = cur - list_h + 1
        top = max(0, min(top, max(0, len(rows) - list_h)))
        mappings = effective_config(dev)
        for i in range(top, min(len(rows), top + list_h)):
            row = rows[i]
            y = list_top + (i - top)
            is_sel = (selectable[sel] == i)
            if row[0] == "header":
                if row[1]:
                    draw_header(scr, y, row[1])
                continue
            if row[0] == "back":
                text = "Back"
                value = ""
            elif row[0] == "test":
                text = "Test this device"
                value = ""
            elif row[0] == "port":
                text = "%-26s" % "Mapped to"
                value = "< %s >" % port_label(cfg, device_port(dev.id))
            elif row[0] == "remove":
                text = "Remove configuration"
                value = ""
            else:
                text = "%-26s" % row[2]
                value = mapping_text(mappings.get(row[1]))
                if i == capture_idx:
                    value = capture_text
            draw_item(scr, y, 4, text, is_sel)
            if value:
                draw_value(scr, y, 6 + len(text) + 2, value, is_sel)
        draw_footer(scr, "Up/Down: select   A/Enter: map/activate   "
                    "Left/Right: port")

    while True:
        draw()
        scr.refresh()

        ch = nav_getch(scr)
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif (ch in (curses.KEY_LEFT, curses.KEY_RIGHT) or ch in KEY_ENTER) \
                and row[0] == "port":
            step = -1 if ch == curses.KEY_LEFT else 1
            p = device_port(dev.id)
            for _ in range(4):
                p = (p + step) % 4
                if port_accepts(cfg, p, dev.kind):
                    break
            if port_accepts(cfg, p, dev.kind):
                PORTS[dev.id] = p
                save_input_config(cfg, devices)
        elif ch in KEY_ENTER:
            idx = selectable[sel]
            row = rows[idx]
            if row[0] == "back":
                return
            if row[0] == "test":
                test_screen(scr, [dev], "Testing: %s" % dev.name)
                nav_flush()
            elif row[0] == "remove":
                # explicit empty config: overrides the per-kind defaults
                CONFIG[dev.id] = {}
                save_input_config(cfg, devices)
            else:  # map
                target = row[1]
                m = capture_mapping(
                    scr, dev,
                    lambda text: draw(capture_idx=idx, capture_text=text),
                    prompt=CAPTURE_PROMPTS.get(target, "Waiting"))
                if m is not None:
                    if target in ANALOG_POS_PROMPTS:
                        if m["kind"] == "key":
                            # that key is the negative (left/up) half of the
                            # axis; now capture the positive one
                            m2 = capture_mapping(
                                scr, dev,
                                lambda text: draw(capture_idx=idx,
                                                  capture_text=text),
                                prompt=ANALOG_POS_PROMPTS[target])
                            pos = (m2["code"]
                                   if m2 is not None and m2["kind"] == "key"
                                   else None)
                            m = {"kind": "keypair", "neg": m["code"],
                                 "pos": pos}
                        else:
                            # the prompted move (left/up) is the negative end
                            # of the DC axis: point the mapping the other way
                            m["dir"] = -m["dir"]
                    if dev.id not in CONFIG:
                        CONFIG[dev.id] = dict(effective_config(dev))
                    CONFIG[dev.id][target] = m
                    save_input_config(cfg, devices)
                nav_flush()  # the captured press also landed in the nav fds


def input_mapper(scr, cfg):
    """Input configuration UI (auto-saves). Returns when the user backs
    out."""
    while True:
        devices = scan_devices()
        res = device_list_screen(scr, devices, cfg)
        if res is None:
            return
        kind, dev = res
        if kind == "test":
            test_screen(scr, devices, "Testing all devices")
            nav_flush()
        else:
            device_screen(scr, dev, cfg, devices)


# -------------------------------------------------------------- curses ui ---

C_TITLE = 1
C_ERROR = 2
C_SEL = 3
C_HEADER = 4
C_DIM = 5
C_VALUE = 6


def init_colors():
    if not curses.has_colors():
        return
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(C_TITLE, curses.COLOR_CYAN, -1)
    curses.init_pair(C_ERROR, curses.COLOR_RED, -1)
    curses.init_pair(C_SEL, curses.COLOR_BLACK, curses.COLOR_WHITE)
    curses.init_pair(C_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(C_DIM, curses.COLOR_WHITE, -1)
    curses.init_pair(C_VALUE, curses.COLOR_GREEN, -1)


# True while the menus draw on the framebuffer (dsui.FbWindow): attributes
# are then plain (pair << 8) | flags - curses' own COLOR_PAIR() encoding -
# which the pixel window maps to the theme colours (fb_styles()).
PIXEL = [False]


def color(pair, extra=0):
    if PIXEL[0]:
        return (pair << 8) | extra
    if curses.has_colors():
        return curses.color_pair(pair) | extra
    return extra


def fb_styles():
    """Colour pair -> (fg, bg) of the pixel UI (ra_osd's palette)."""
    return {0: (dsui.TEXT, None), C_TITLE: (dsui.GOLD, None),
            C_ERROR: (dsui.RED, None), C_SEL: (dsui.TEXT, dsui.HILITE),
            C_HEADER: (dsui.GOLD, None), C_DIM: (dsui.DIM, None),
            C_VALUE: (dsui.BLUE, None)}


def is_pixel(scr):
    return getattr(scr, "is_pixel", False)


def safe_addstr(scr, y, x, text, attr=0):
    h, w = scr.getmaxyx()
    if y < 0 or y >= h or x >= w:
        return
    # curses can't write the bottom-right cell; the pixel grid can
    room = w - x if is_pixel(scr) else w - x - 1
    try:
        scr.addstr(y, x, text[: max(0, room)], attr)
    except curses.error:
        pass


def draw_title(scr, subtitle=""):
    _, w = scr.getmaxyx()
    scr.erase()
    if is_pixel(scr):
        # like the emulator's lists: gold title, the context line under it,
        # a thin rule (grid row 2) - all left-aligned
        safe_addstr(scr, 0, 0, TITLE, color(C_TITLE))
        if subtitle:
            safe_addstr(scr, 1, 0, subtitle)
        return
    safe_addstr(scr, 0, max(0, (w - len(TITLE)) // 2), TITLE,
                color(C_TITLE, curses.A_BOLD))
    if subtitle:
        safe_addstr(scr, 1, max(0, (w - len(subtitle)) // 2), subtitle,
                    color(C_DIM))
    safe_addstr(scr, 2, 0, "-" * (w - 1), color(C_DIM))


# Row helpers shared by the screens. curses keeps its original look ("> "
# marker, reversed text); the pixel UI uses a full-width highlight bar,
# items indented under gold section names and right-aligned values.
PX_ITEM_X = 2


def fit(text, n):
    """At most n chars; longer text ends in '...' (ra_osd's ra_fit)."""
    if len(text) <= n:
        return text
    return text[:max(0, n - 3)] + "..." if n >= 3 else text[:max(0, n)]


def sel_bar(scr, y):
    if is_pixel(scr):
        scr.bar(y)
    else:
        _, w = scr.getmaxyx()
        safe_addstr(scr, y, 1, " " * (w - 3), color(C_SEL))


def draw_item(scr, y, x, text, selected, attr=0, bar=True):
    """A menu entry; x = its curses column when not selected."""
    if is_pixel(scr):
        if selected:
            scr.bar(y)
        _, w = scr.getmaxyx()
        safe_addstr(scr, y, PX_ITEM_X, fit(text.rstrip(), w - PX_ITEM_X),
                    color(C_SEL) if selected else attr)
        return
    if selected:
        if bar:
            sel_bar(scr, y)
        safe_addstr(scr, y, x - 2, "> " + text, color(C_SEL, curses.A_BOLD))
    else:
        safe_addstr(scr, y, x, text, attr)


def draw_value(scr, y, x, text, selected, attr=None, right=0):
    """A setting's value: at column x in curses, right-aligned (leaving
    `right` columns free) in the pixel UI."""
    if attr is None:
        attr = color(C_VALUE)
    if is_pixel(scr):
        _, w = scr.getmaxyx()
        safe_addstr(scr, y, max(0, w - right - len(text)), text,
                    color(C_SEL) if selected else attr)
    else:
        safe_addstr(scr, y, x, text,
                    color(C_SEL, curses.A_BOLD) if selected else attr)


def draw_header(scr, y, text):
    if is_pixel(scr):
        safe_addstr(scr, y, 0, text, color(C_HEADER))
    else:
        safe_addstr(scr, y, 2, "[ %s ]" % text, color(C_HEADER, curses.A_BOLD))


def draw_footer(scr, text, pos=""):
    """Help line; pos (pixel UI only) goes right-aligned, e.g. '12/140'."""
    h, w = scr.getmaxyx()
    if is_pixel(scr):
        if pos and len(text) + len(pos) + 1 > w:
            text = text[:max(0, w - len(pos) - 4)] + "..."
        safe_addstr(scr, h - 1, 0, text, color(C_DIM))
        if pos:
            safe_addstr(scr, h - 1, w - len(pos), pos, color(C_DIM))
    else:
        safe_addstr(scr, h - 1, 1, text, color(C_DIM))


def list_geom(scr, top, gap=2):
    """(first row, rows) of a screen's list. The pixel grid has the title
    rule on row 2 instead of a text row of dashes, and its own rule above
    the help line, so lists start a row higher and end a row lower."""
    h, _ = scr.getmaxyx()
    if is_pixel(scr):
        top, gap = top - 1, gap - 1
    return top, max(1, h - top - gap)


def scroll_pos(top, visible, total, index=None, count=None):
    """ra_osd-style position: up/down arrows while there is more above or
    below, then 'n/N'."""
    arrows = (u"\u25b2" if top > 0 else " ") + \
             (u"\u25bc" if top + visible < total else " ")
    if index is None:
        return arrows.strip() and arrows
    return "%s %d/%d" % (arrows, index, count)


def error_screen(scr, lines):
    draw_title(scr)
    h, _ = scr.getmaxyx()
    y = h // 2 - len(lines) // 2
    for i, line in enumerate(lines):
        _, w = scr.getmaxyx()
        safe_addstr(scr, y + i, max(0, (w - len(line)) // 2), line,
                    color(C_ERROR, curses.A_BOLD))
    msg = "Press any button to exit"
    safe_addstr(scr, y + len(lines) + 2,
                max(0, (scr.getmaxyx()[1] - len(msg)) // 2), msg, color(C_DIM))
    scr.refresh()
    scr.getch()


def main_menu_screen(scr, games, game_dirs):
    """Returns ("configure",), ("bios",), ("game", label, path), or None
    to exit."""
    rows = [("header", "System"),
            ("configure", None),
            ("bios", None),
            ("exit", None),
            ("header", "Disc Images")]
    rows += [("game", (name, path))
             for name, (_, path) in zip(display_names(games), games)]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    # default to the first disc image if any, otherwise Boot To Bios
    sel = 3 if games else 1
    top = 0
    while True:
        source = (game_dirs[0] if len(game_dirs) == 1
                  else "%d folders" % len(game_dirs))
        draw_title(scr, "%d game(s) found in %s" % (len(games), source))
        list_top, list_h = list_geom(scr, 4)

        cur = selectable[sel]
        if cur < top:
            top = cur
        if cur >= top + list_h:
            top = cur - list_h + 1
        top = max(0, min(top, max(0, len(rows) - list_h)))

        for i in range(top, min(len(rows), top + list_h)):
            kind, payload = rows[i]
            y = list_top + (i - top)
            if kind == "header":
                draw_header(scr, y, payload)
                continue
            if kind == "configure":
                text = "Configure"
            elif kind == "bios":
                text = "Boot To Bios"
            elif kind == "exit":
                text = "Exit To MiSTer"
            else:
                text = payload[0]
            draw_item(scr, y, 4, text, i == cur)

        pos = ""
        if rows[cur][0] == "game":
            pos = scroll_pos(top, list_h, len(rows), cur - 4, len(games))
        else:
            pos = scroll_pos(top, list_h, len(rows))
        draw_footer(scr, "Up/Down: select   Left/Right: page   A/Enter: open",
                    pos)
        scr.refresh()

        ch = nav_getch(scr)
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in (curses.KEY_LEFT, curses.KEY_RIGHT):
            # a page at a time, stopping at the ends (no wrap-around)
            step = list_h if ch == curses.KEY_RIGHT else -list_h
            target = max(0, min(len(rows) - 1, cur + step))
            sel = min(range(len(selectable)),
                      key=lambda s: abs(selectable[s] - target))
            top += step
        elif ch in KEY_ENTER:
            kind, payload = rows[selectable[sel]]
            if kind == "game":
                return ("game", payload[0], payload[1])
            if kind == "exit":
                return None
            return (kind,)


def rebuild_nav():
    """Recreates the evdev nav pump after input mappings may have changed."""
    if NAV[0] is not None:
        NAV[0].close()
        NAV[0] = NavPump()


def confirm_screen(scr, lines, subtitle="Are you sure?", yes="Yes", no="No"):
    """Modal two-way dialog; returns True on the yes option. Defaults to
    the no option."""
    sel = 1  # 0 = yes, 1 = no
    while True:
        draw_title(scr, subtitle)
        h, w = scr.getmaxyx()
        y = max(4, h // 2 - len(lines) // 2 - 2)
        for i, line in enumerate(lines):
            safe_addstr(scr, y + i, max(0, (w - len(line)) // 2), line,
                        curses.A_BOLD if i == 0 else 0)
        yb = min(h - 3, y + len(lines) + 2)
        labels = ("  %s  " % yes, "  %s  " % no)
        if is_pixel(scr):
            # two buttons, the selected one on the highlight colour
            x = max(0, (w - len(labels[0]) - len(labels[1]) - 6) // 2)
            for i, lab in enumerate(labels):
                safe_addstr(scr, yb, x, lab,
                            color(C_SEL) if i == sel else color(C_DIM))
                x += len(lab) + 6
        else:
            x = max(0, w // 2 - 14)
            for i, lab in enumerate(labels):
                if i == sel:
                    safe_addstr(scr, yb, x, "> " + lab,
                                color(C_SEL, curses.A_BOLD))
                else:
                    safe_addstr(scr, yb, x, "  " + lab)
                x += len(lab) + 8
        draw_footer(scr, "Left/Right: select   A/Enter: confirm")
        scr.refresh()
        ch = nav_getch(scr)
        if ch in (curses.KEY_LEFT, curses.KEY_RIGHT,
                  curses.KEY_UP, curses.KEY_DOWN):
            sel ^= 1
        elif ch in KEY_ENTER:
            return sel == 0


OVERCLOCK_WARNING = [
    "Enable the 1 GHz CPU overclock?",
    "",
    "This runs the DE10-Nano's HPS above its stock",
    "800 MHz. It may be unstable on some boards:",
    "crashes, corrupted data or hangs are possible.",
    "The stock clock is restored when the emulator",
    "exits.",
]

OVERCLOCK12_WARNING = [
    "Enable the 1.2 GHz CPU overclock?",
    "",
    "50% above the HPS's stock 800 MHz, at the same",
    "voltage. Less likely to be stable than 1 GHz:",
    "if a game crashes, hangs or glitches, go back",
    "to 1 GHz. More heat too - keep the case",
    "ventilated. Restored to 800 MHz on exit.",
]

RESTORE_WARNING = [
    "Restore ALL settings to their defaults?",
    "",
    "Every Configure option, the Dreamcast peripheral",
    "assignments and all saved input mappings will be",
    "reset. This cannot be undone.",
]

VERSION_WARNING = [
    "Configuration reset required",
    "",
    "Your DreamSTer configuration was written by a",
    "different release (expected version %s)." % CFG_VERSION,
    "",
    "OK resets ALL configuration to defaults.",
    "Exit returns to MiSTer, leaving it untouched.",
]


def peripherals_screen(scr, cfg):
    """Dreamcast Peripherals: what maple device sits on each port."""
    rows = [("back",), ("header", "Maple Ports")]
    rows += [("port", p) for p in range(4)]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0
    while True:
        draw_title(scr, "Dreamcast Peripherals")
        list_top, _ = list_geom(scr, 4)
        for i, row in enumerate(rows):
            y = list_top + i
            is_sel = (selectable[sel] == i)
            if row[0] == "header":
                draw_header(scr, y, row[1])
                continue
            if row[0] == "back":
                text = "Back"
                value = ""
            else:
                port = row[1]
                text = "%-26s" % PORT_NAMES[port]
                pid = get_port_peripheral(cfg, port)
                value = "< %s >" % PERIPHERAL_LABELS.get(pid, "Custom")
            draw_item(scr, y, 4, text, is_sel)
            if value:
                draw_value(scr, y, 6 + len(text) + 2, value, is_sel)
        draw_footer(scr, "Up/Down: select   Left/Right/A: change")
        scr.refresh()

        ch = nav_getch(scr)
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER and row[0] == "back":
            return
        elif (ch in (curses.KEY_LEFT, curses.KEY_RIGHT) or ch in KEY_ENTER) \
                and row[0] == "port":
            port = row[1]
            step = -1 if ch == curses.KEY_LEFT else 1
            ids = [pid for pid, _, _ in PERIPHERALS]
            pid = get_port_peripheral(cfg, port)
            idx = ids.index(pid) if pid in ids else -1
            set_port_peripheral(cfg, port, ids[(idx + step) % len(ids)])
            save_cfg(cfg)


def draw_config_row(scr, y, row, sel, cfg, gcfg):
    """One Configure row in the pixel UI: label on the left, value
    right-aligned, a gold '*' in the last column for a per-game value."""
    kind = row[0]
    mark = 2 if gcfg is not None else 0      # columns kept for the marker
    if kind == "header":
        draw_header(scr, y, row[1])
    elif kind == "launch":
        draw_item(scr, y, 0, "Launch", sel, attr=curses.A_BOLD)
    elif kind == "back":
        draw_item(scr, y, 0, "Back", sel)
    elif kind == "scope":
        draw_item(scr, y, 0, "Settings apply to", sel)
        draw_value(scr, y, 0, "< %s >" % ("This game" if gcfg.per_game
                                          else "All games"),
                   sel, attr=color(C_HEADER), right=mark)
    elif kind == "clear":
        draw_item(scr, y, 0, "Clear this game's settings (*)"
                  if gcfg.has_overrides() else "(no per-game settings)",
                  sel, attr=color(C_DIM))
    elif kind in ("page", "restore"):
        draw_item(scr, y, 0, "Restore Defaults" if kind == "restore"
                  else "%s ..." % row[1], sel)
    else:
        opt = row[1]
        on = opt.enabled(cfg)
        dim = color(C_DIM)
        draw_item(scr, y, 0, opt.label, sel and on, attr=0 if on else dim)
        draw_value(scr, y, 0, "< %s >" % opt.display(cfg), sel and on,
                   attr=None if on else dim, right=mark)
        if gcfg is not None and gcfg.is_overridden(opt.section, opt.key):
            _, w = scr.getmaxyx()
            safe_addstr(scr, y, w - 1, "*", color(C_HEADER))


def configure_screen(scr, cfg, subtitle, launch=False, game=None):
    """The Configure menu. With launch=True a Launch entry is pinned on
    top (pre-launch flow); returns True to launch, False/None otherwise.
    With a game, options can be set for that game only (per-game file)."""
    # rows: ("launch",), ("back",), ("header", text), ("opt", Option),
    #       ("page", label, target), ("restore",), ("scope",), ("clear",)
    gcfg = None
    if game is not None:
        gcfg = effective_cfg(game, base=cfg)
        gcfg.per_game = gcfg.has_overrides()
        cfg = gcfg
    rows = [("launch",)] if launch else []
    rows += [("back",)]
    if gcfg is not None:
        rows += [("scope",), ("clear",)]
    rows += [("header", "CRT"),
             ("opt", CRT_VOL_OPT), ("opt", VIDEO_OPT), ("opt", FIELD_OPT),
             ("opt", VFILTER_OPT), ("opt", ANALOG_OPT), ("opt", WIFI_OPT),
             ("opt", VMU_OPT), ("opt", RA_OPT), ("opt", AUDIO_THREAD_OPT), ("opt", RA_POPUPS_OPT),
             ("opt", CRT_CLOCK_OPT), ("opt", CRT_EMU_OPT)]
    rows += [("header", "Dreamcast"),
             ("opt", REGION_OPT), ("opt", CABLE_OPT),
             ("page", "Dreamcast Peripherals", "periph")]
    rows += [("header", "DE10-Nano"),
             ("opt", OVERCLOCK_OPT),
             ("page", "Input Mapping", "inputmap")]
    rows += [("header", "Minicast"),
             ("opt", TIMEREC_OPT), ("opt", AUDIO_OPT), ("opt", FPS_OPT),
             ("opt", OPTMODE_OPT)]
    rows += [("opt", o) for o in OPT_ITEMS]
    rows += [("header", "polly2"),
             ("opt", AUTORESET_OPT), ("opt", CLOCK_OPT), ("opt", DUMP_OPT)]
    rows += [("header", "Danger Zone"), ("restore",)]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0  # Launch (pre-launch flow) / Back

    # headers take two lines (blank + text), everything else one
    heights = [2 if r[0] == "header" else 1 for r in rows]
    offsets = []
    total = 0
    for hh in heights:
        offsets.append(total)
        total += hh
    top = 0

    while True:
        draw_title(scr, subtitle)
        h, w = scr.getmaxyx()
        list_top, list_h = list_geom(scr, 4)
        cur = selectable[sel]
        if offsets[cur] < top:
            top = offsets[cur]
        if offsets[cur] + heights[cur] > top + list_h:
            top = offsets[cur] + heights[cur] - list_h
        top = max(0, min(top, max(0, total - list_h)))

        def put(yv, x, text, attr=0):
            y = list_top + yv - top
            if list_top <= y < list_top + list_h:
                safe_addstr(scr, y, x, text, attr)

        if is_pixel(scr):
            for i, row in enumerate(rows):
                yv = offsets[i] + (1 if row[0] == "header" else 0)
                y = list_top + yv - top
                if list_top <= y < list_top + list_h:
                    draw_config_row(scr, y, row, selectable[sel] == i,
                                    cfg, gcfg)
            draw_footer(scr, "Up/Down: select   Left/Right/A: change"
                        + ("   * = this game only" if gcfg is not None
                           and gcfg.has_overrides() else ""),
                        scroll_pos(top, list_h, total))
        else:
            for i, row in enumerate(rows):
                yv = offsets[i]
                is_sel = (selectable[sel] == i)
                if row[0] == "launch":
                    text = "  Launch  "
                    if is_sel:
                        put(yv, 4, ">" + text, color(C_SEL, curses.A_BOLD))
                    else:
                        put(yv, 5, text, curses.A_BOLD)
                elif row[0] == "back":
                    text = "  Back  "
                    if is_sel:
                        put(yv, 4, ">" + text, color(C_SEL, curses.A_BOLD))
                    else:
                        put(yv, 5, text)
                elif row[0] == "scope":
                    label = "%-28s" % "Settings apply to"
                    value = "< %s >" % ("This game" if gcfg.per_game else "All games")
                    attr = color(C_SEL, curses.A_BOLD) if is_sel else color(C_VALUE, curses.A_BOLD)
                    put(yv, 4 if is_sel else 6, ("> " if is_sel else "") + label,
                        color(C_SEL, curses.A_BOLD) if is_sel else 0)
                    put(yv, 6 + len(label) + 2, value, attr)
                elif row[0] == "clear":
                    text = ("Clear this game's settings (*)" if gcfg.has_overrides()
                            else "(no per-game settings)")
                    if is_sel:
                        put(yv, 4, "> " + text, color(C_SEL, curses.A_BOLD))
                    else:
                        put(yv, 6, text, color(C_DIM))
                elif row[0] == "header":
                    put(yv + 1, 2, "[ %s ]" % row[1],
                        color(C_HEADER, curses.A_BOLD))
                elif row[0] in ("page", "restore"):
                    text = ("Restore Defaults" if row[0] == "restore"
                            else "%s ..." % row[1])
                    if is_sel:
                        put(yv, 4, "> " + text, color(C_SEL, curses.A_BOLD))
                    else:
                        put(yv, 6, text)
                else:
                    opt = row[1]
                    label = "%-28s" % opt.label
                    value = "< %s >" % opt.display(cfg)
                    if gcfg is not None and gcfg.is_overridden(opt.section, opt.key):
                        value += " *"
                    if not opt.enabled(cfg):
                        put(yv, 6, label, color(C_DIM))
                        put(yv, 6 + len(label) + 2, value, color(C_DIM))
                    elif is_sel:
                        put(yv, 4, "> " + label, color(C_SEL, curses.A_BOLD))
                        put(yv, 6 + len(label) + 2, value,
                            color(C_SEL, curses.A_BOLD))
                    else:
                        put(yv, 6, label)
                        put(yv, 6 + len(label) + 2, value, color(C_VALUE))
            draw_footer(scr, "Up/Down: select   Left/Right/A: change")
        scr.refresh()

        def move_sel(delta):
            # skip disabled options (grayed out, not selectable)
            s = sel
            for _ in range(len(selectable)):
                s = (s + delta) % len(selectable)
                r = rows[selectable[s]]
                if r[0] != "opt" or r[1].enabled(cfg):
                    return s
            return sel

        ch = nav_getch(scr)
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = move_sel(-1)
        elif ch == curses.KEY_DOWN:
            sel = move_sel(1)
        elif ch in KEY_ENTER and row[0] == "launch":
            return True
        elif ch in KEY_ENTER and row[0] == "back":
            return False
        elif row[0] == "scope" and (ch in (curses.KEY_LEFT, curses.KEY_RIGHT)
                                    or ch in KEY_ENTER):
            gcfg.per_game = not gcfg.per_game
        elif ch in KEY_ENTER and row[0] == "clear":
            if gcfg.has_overrides():
                gcfg.clear_overrides()
                gcfg.per_game = False
                save_cfg(gcfg)
        elif ch in KEY_ENTER and row[0] == "page":
            base_cfg = gcfg.base if gcfg is not None else cfg
            if row[2] == "periph":
                peripherals_screen(scr, base_cfg)
            else:
                input_mapper(scr, base_cfg)
                rebuild_nav()
        elif ch in KEY_ENTER and row[0] == "restore":
            if confirm_screen(scr, RESTORE_WARNING, "Danger Zone"):
                restore_defaults(gcfg.base if gcfg is not None else cfg)
                rebuild_nav()
        elif ch in (curses.KEY_LEFT, curses.KEY_RIGHT) or ch in KEY_ENTER:
            if row[0] == "opt" and row[1].enabled(cfg):
                opt = row[1]
                if opt is OVERCLOCK_OPT:
                    # each overclock step only engages after an explicit warning
                    order = ["0", "1", "2"]
                    cur = opt.current(cfg)
                    cur = cur if cur in order else "0"
                    new = order[(order.index(cur) +
                                 (-1 if ch == curses.KEY_LEFT else 1)) % 3]
                    if new == "1" and not confirm_screen(
                            scr, OVERCLOCK_WARNING, "DE10-Nano Overclock"):
                        continue
                    if new == "2" and not confirm_screen(
                            scr, OVERCLOCK12_WARNING, "DE10-Nano Overclock"):
                        continue
                    opt.set(cfg, new)
                else:
                    opt.cycle(cfg, -1 if ch == curses.KEY_LEFT else 1)
                save_cfg(cfg)


def ui(scr):
    """Runs the curses UI. Returns game path to launch, or None."""
    curses.curs_set(0)
    scr.keypad(True)
    # drop keys queued on the tty while a game ran (e.g. the Start+L ESC)
    curses.flushinp()
    try:
        curses.set_escdelay(50)
    except AttributeError:
        pass
    init_colors()

    missing = [p for p in (BOOT_BIN, FLASH_BIN) if not os.path.isfile(p)]
    if missing:
        error_screen(scr, ["ERROR: required file missing:"] +
                     ["  %s" % p for p in missing])
        return None

    cfg = load_cfg()
    if cfg.get("dreamster", "Version", fallback="").strip() != CFG_VERSION:
        if not confirm_screen(scr, VERSION_WARNING, "Configuration Reset",
                              yes="OK", no="Exit"):
            return None
        cfg = reset_all_configuration()
    load_input_config(cfg)

    game_dirs = resolve_game_dirs(cfg)
    games = scan_games(game_dirs)
    if should_wait_for_external(cfg, game_dirs, games):
        wait_seconds = startup_storage_wait_seconds()
        if wait_seconds > 0:
            draw_title(scr, "Waiting for USB/NVMe game storage...")
            scr.refresh()
            external = wait_for_external_game_dir(wait_seconds)
            if external:
                game_dirs = resolve_game_dirs(cfg)
                games = scan_games(game_dirs)
    GAME_LIST[:] = games          # for the emulator's games.json

    NAV[0] = NavPump()
    try:
        while True:
            res = main_menu_screen(scr, games, game_dirs)
            if res is None:
                return None
            if res[0] == "configure":
                configure_screen(scr, cfg, "Configure")
                continue
            if res[0] == "bios":
                game = "nodisk"
                subtitle = "Boot To Bios"
            else:
                game = res[2]
                subtitle = res[1]
            if configure_screen(scr, cfg, subtitle, launch=True, game=game):
                return game
    finally:
        NAV[0].close()
        NAV[0] = None


# the game list the menu showed last: (label, path) as from scan_games()
GAME_LIST = []

# ---- pixel UI session ------------------------------------------------------
# One framebuffer session for the whole run (menus, the loading notice, the
# game, the list again through the console mirror): the console stays in
# KD_GRAPHICS so nothing the launcher prints in between lands on the picture,
# and it is handed back (KD_TEXT, pixels restored) before MiSTer restarts.
DISPLAY = [None]
_CONSOLE_RE = re.compile(r"/dev/(tty\d+|console)$")


def ui_overscan(cfg):
    """[dreamster] UiOverscan = x,y - percent of each edge kept clear
    (blank: the emulator's own margins, 32 px / 12 lines)."""
    v = cfg.get("dreamster", "UiOverscan", fallback="").strip()
    try:
        x, y = (float(p) for p in v.split(","))
        return (max(0.0, min(x, 25.0)), max(0.0, min(y, 25.0)))
    except ValueError:
        return None


def open_display():
    """Starts the pixel UI if it can run here; None = curses UI."""
    want = os.environ.get("DREAMSTER_UI", "").strip().lower()
    if want == "curses" or dsui is None:
        return None
    if want != "fb":
        # only on the console itself: over ssh (a pty) the picture would be
        # on a screen nobody running the menu can see
        try:
            if not _CONSOLE_RE.match(os.ttyname(1)):
                return None
        except OSError:
            return None
    try:
        d = dsui.FbDisplay.open_device(overscan=ui_overscan(load_cfg()))
    except Exception as e:
        crt_log("pixel ui unavailable (%s): curses ui" % e)
        return None
    crt_log("pixel ui: %s" % d.describe())
    DISPLAY[0] = d
    PIXEL[0] = True
    return d


def close_display():
    d = DISPLAY[0]
    DISPLAY[0] = None
    PIXEL[0] = False
    if d is not None:
        try:
            d.close()
        except Exception as e:
            crt_log("pixel ui close: %s" % e)


def text_console():
    """Curses UI on the console: make sure the VT draws text (a pixel UI
    killed with SIGKILL leaves it in KD_GRAPHICS)."""
    try:
        if _CONSOLE_RE.match(os.ttyname(1)):
            fcntl.ioctl(1, 0x4B3A, 0)         # KDSETMODE KD_TEXT
    except OSError:
        pass


def run_ui():
    """The menus, on the framebuffer when a pixel session is open. Returns
    the game to launch or None."""
    d = DISPLAY[0]
    if d is None:
        return curses.wrapper(ui)
    try:
        if d.check_geometry():
            crt_log("pixel ui: mode changed, %s" % d.describe())
    except Exception as e:
        crt_log("pixel ui: geometry check failed: %s" % e)

    def pixel_ui(stdscr):
        # curses still owns the tty (keys, escape sequences, ssh) - it just
        # never draws: the VT is in graphics mode
        return ui(dsui.FbWindow(d, stdscr, fb_styles(), curses.A_BOLD))
    return curses.wrapper(pixel_ui)


def pixel_notice(subtitle, lines=(), footer=""):
    """A static page on the framebuffer (e.g. while a game loads)."""
    d = DISPLAY[0]
    if d is None:
        return
    try:
        win = dsui.FbWindow(d, None, fb_styles(), curses.A_BOLD)
        draw_title(win, subtitle)
        h, w = win.getmaxyx()
        y = max(3, h // 2 - len(lines) // 2 - 1)
        for i, line in enumerate(lines):
            safe_addstr(win, y + i, max(0, (w - len(line)) // 2), line,
                        curses.A_BOLD if i == 0 else color(C_DIM))
        if footer:
            draw_footer(win, footer)
        win.refresh()
    except Exception as e:
        crt_log("pixel notice failed: %s" % e)


# ---------------------------------------------------------------- launch ---

def run(cmd, **kw):
    print("+ " + " ".join(cmd))
    sys.stdout.flush()
    return subprocess.call(cmd, **kw)


# The MiSTer main binary that launched us: pid = our parent, exe read from
# /proc/<ppid>/exe. Falls back to killall + MISTER_BIN when the parent is
# something else (e.g. a shell during development).
MISTER = {"pid": None, "exe": MISTER_BIN}


def _proc_exe(pid):
    try:
        return os.readlink("/proc/%d/exe" % pid).replace(" (deleted)", "")
    except OSError:
        return None


def _is_main_binary(exe):
    """The MiSTer main binary or one of its forks (MiSTer_ConsoleMode,
    MiSTer_RA, ...) - whatever main= in MiSTer.ini points at."""
    return exe is not None and os.path.basename(exe).startswith("MiSTer")


def detect_parent_mister():
    ppid = os.getppid()
    exe = _proc_exe(ppid)
    if exe is not None and os.path.basename(exe) == os.path.basename(MISTER_BIN):
        MISTER["pid"] = ppid
        MISTER["exe"] = exe
        return
    # a forked main binary (Console Mode's MiSTer_ConsoleMode runs scripts on
    # tty2 from its own host): find it, parent or not. Killing it would hang
    # up the terminal we run on, and a stock MiSTer restart would not bring
    # its frontend back - so it is paused instead and resumed on exit.
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == os.getpid():
            continue
        exe = _proc_exe(int(d))
        if _is_main_binary(exe) and os.path.basename(exe) != os.path.basename(MISTER_BIN):
            try:
                with open("/proc/%s/cmdline" % d, "rb") as f:
                    argv = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
                cwd = os.readlink("/proc/%s/cwd" % d)
            except OSError:
                argv, cwd = [exe], "/"
            MISTER.update(pid=int(d), exe=exe, argv=argv, cwd=cwd, fork=True)
            return


def _proc_running(pid):
    """True while pid exists and is not a zombie."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(") ", 1)[1][0] != "Z"
    except (OSError, IndexError):
        return False


def _fork_menu_rbf():
    """The menu core a forked main binary was started with (its .rbf arg)."""
    for a in MISTER.get("argv", [])[1:]:
        if a.lower().endswith(".rbf"):
            path = a if os.path.isabs(a) else os.path.join(MISTER.get("cwd", "/"), a)
            if os.path.exists(path):
                return path
            alt = os.path.join("/media/fat", a)
            if os.path.exists(alt):
                return alt
    return MENU_RBF


def kill_mister():
    """Stops the MiSTer main binary so it releases input/video/audio."""
    pid = MISTER["pid"]
    if pid is not None and MISTER.get("fork"):
        # paused, not killed (see detect_parent_mister): it stops reading the
        # pads / feeding the terminal and keeps its place until we resume it
        try:
            os.kill(pid, signal.SIGSTOP)
            MISTER["stopped"] = True
            crt_log("paused %s (pid %d)" % (MISTER["exe"], pid))
        except OSError:
            pass
        return
    if pid is not None:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        for _ in range(20):  # wait up to 2s for it to actually go away
            if not _proc_running(pid):
                return
            time.sleep(0.1)
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        return
    subprocess.call(["killall", "MiSTer"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(20):  # wait up to 2s for it to actually go away
        if subprocess.call(["pidof", "MiSTer"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL) != 0:
            return
        time.sleep(0.1)


def _send_main_cmd(line, attempts=40):
    """One line to Main's command FIFO, which vanishes briefly on core loads."""
    for _ in range(attempts):
        try:
            fd = os.open("/dev/MiSTer_cmd", os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            time.sleep(0.25)
            continue
        try:
            os.write(fd, (line + "\n").encode())
            return True
        except OSError:
            return False
        finally:
            os.close(fd)
    return False


def restart_mister():
    """Reloads the menu core and brings the MiSTer main binary back up."""
    if MISTER.get("stopped"):
        MISTER["stopped"] = False
        rbf = _fork_menu_rbf()
        print("\nresuming %s..." % os.path.basename(MISTER["exe"]))
        try:
            run([LOAD_BITSTREAM, rbf], cwd=MINICAST_DIR)
        except OSError as e:
            print("menu core reload failed: %s" % e)
        # Resuming the paused host does not work out: it set its core's video
        # (scaler, mode) up before the pause and the reload above reset that,
        # so its UI comes back scrambled; making it reload its core (load_core)
        # while this script still runs loses its post-script UI relaunch, and
        # a re-exec'd host only starts the UI on a first start - which it
        # detects as /tmp/consolemode_exit_code being absent. So do what a
        # boot does, once this process is gone: a detached helper stops the
        # paused host, clears its exit-code / script-path state and starts it
        # fresh with the same argv and cwd - video set up and UI launched as
        # at power-on.
        import shlex
        pid = MISTER["pid"]
        argv = MISTER.get("argv") or [MISTER["exe"], rbf]
        cwd = MISTER.get("cwd") or "/"
        helper = (
            "while kill -0 %d 2>/dev/null; do sleep 0.2; done; "
            "kill -KILL %d 2>/dev/null; "
            "while kill -0 %d 2>/dev/null; do sleep 0.1; done; "
            "killall ConsoleMode_arm 2>/dev/null; "
            "rm -f /tmp/consolemode_exit_code /tmp/consolemode_script_path; "
            "cd %s && exec %s"
        ) % (os.getpid(), pid, pid, shlex.quote(cwd),
             " ".join(shlex.quote(a) for a in argv))
        try:
            with open(os.devnull, "rb+") as devnull:
                subprocess.Popen(["sh", "-c", helper], stdin=devnull,
                                 stdout=devnull, stderr=devnull,
                                 start_new_session=True)
            crt_log("restarting %s fresh after exit: %s (cwd %s)"
                    % (os.path.basename(MISTER["exe"]), argv, cwd))
        except OSError as e:
            crt_log("fresh restart failed (%s); resuming instead" % e)
            try:
                os.kill(pid, signal.SIGCONT)
            except OSError:
                pass
        return
    print("\nrestarting MiSTer...")
    try:
        run([LOAD_BITSTREAM, MENU_RBF], cwd=MINICAST_DIR)
    except OSError as e:
        print("menu core reload failed: %s" % e)
    mister = MISTER["exe"] or MISTER_BIN
    try:
        with open(os.devnull, "rb+") as devnull:
            subprocess.Popen([mister], cwd=os.path.dirname(mister),
                             stdin=devnull, stdout=devnull, stderr=devnull,
                             start_new_session=True)
    except OSError as e:
        print("MiSTer restart failed: %s" % e)


CPUFREQ_DIR = "/sys/devices/system/cpu/cpu0/cpufreq"


def _cpufreq_read(name):
    try:
        with open(os.path.join(CPUFREQ_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return None


CPUFREQ_BOOST = "/sys/devices/system/cpu/cpufreq/boost"


def _cpufreq_prepare():
    """MiSTer 6.x kernels ship the SoCFPGA cpufreq driver as a module and keep
    1.0/1.2 GHz as opt-in boost frequencies: load it and enable boost."""
    if not os.path.isdir(CPUFREQ_DIR):
        run(["modprobe", "socfpga-cpufreq"])
        time.sleep(0.5)
    # park at the minimum while boost is enabled, else the performance
    # governor briefly runs the new top step (1.2 GHz) before the 1 GHz cap
    _cpufreq_write("scaling_governor", "powersave")
    try:
        with open(CPUFREQ_BOOST, "w") as f:
            f.write("1")
    except OSError as e:
        print("cpufreq: boost opt-in failed: %s" % e)
    _cpufreq_write("scaling_max_freq", "1000000")
    crt_log("overclock: cpufreq %s, max %s" % (
        "present" if os.path.isdir(CPUFREQ_DIR) else "MISSING",
        _cpufreq_read("cpuinfo_max_freq")))


def _cpufreq_write(name, value):
    try:
        with open(os.path.join(CPUFREQ_DIR, name), "w") as f:
            f.write(value)
        return True
    except OSError as e:
        print("cpufreq: %s <- %s failed: %s" % (name, value, e))
        return False


# The CRT bitstreams are built with Quartus Lite and only hold timing at the
# lowest core clock; force the CRT Clock option (75 MHz by default) while they
# run, then put the user's value back so the stock (1080p) DreamSTer keeps its
# own setting.
_CLOCKSEL_RE = re.compile(r"^(\s*polly2\.ClockSel\s*=\s*)(\S*)", re.M)


def _force_clocksel(value):
    """Set polly2.ClockSel in emu.cfg; returns the previous value (None if absent)."""
    try:
        with open(CFG_PATH) as f:
            text = f.read()
    except OSError:
        return None
    m = _CLOCKSEL_RE.search(text)
    if not m:
        return None
    if m.group(2) != value:
        with open(CFG_PATH, "w") as f:
            f.write(_CLOCKSEL_RE.sub(lambda mm: mm.group(1) + value, text, count=1))
    return m.group(2)


# ---- CRT volume: pvr_mmio AUDIO_VOL (MiSTer vol_att encoding) -----------
MISTER_VOLUME = "/media/fat/config/Volume.dat"
RSTMGR_BASE, RSTMGR_BRGMODRST = 0xFFD05000, 0x1C   # [1] = LW H2F bridge in reset
PVR_CFG_BASE, PVR_AUDIO_VOL = 0xFF202000, 0x28
PVR_AUDIO_VOL_R7, PVR_REVISION = 0x30, 0x1C
VOL_KEYS = {113: "mute", 114: "down", 115: "up"}  # KEY_MUTE / VOLUMEDOWN / VOLUMEUP


def crt_volume_att(cfg):
    """[3:0] 6 dB steps, [4] mute: the CRT Volume option, or MiSTer's own."""
    v = CRT_VOL_OPT.current(cfg)
    if v == "mute":
        return 0x10
    if v.isdigit():
        return min(int(v), 7)
    try:
        with open(MISTER_VOLUME, "rb") as f:
            b = f.read(1)
        if b:
            return b[0] & 0x17
    except OSError:
        pass
    return 4


def write_audio_vol(att):
    """Poke AUDIO_VOL, only while the LW bridge is out of reset (else SIGBUS)."""
    try:
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    except OSError:
        return False
    try:
        m = mmap.mmap(fd, 4096, offset=RSTMGR_BASE)
        brg = struct.unpack_from("<I", m, RSTMGR_BRGMODRST)[0]
        m.close()
        if brg & 0x2:
            return False
        m = mmap.mmap(fd, 4096, offset=PVR_CFG_BASE)
        # r6-based CRT builds (REVISION 3) keep AUDIO_VOL at 0x28; on r7
        # (REVISION >= 6) 0x28 is VRAM_CFG and AUDIO_VOL moved to 0x30
        rev = struct.unpack_from("<I", m, PVR_REVISION)[0]
        struct.pack_into("<I", m, PVR_AUDIO_VOL_R7 if rev >= 6 else PVR_AUDIO_VOL,
                         att & 0x1F)
        m.close()
        return True
    except (OSError, ValueError):
        return False
    finally:
        os.close(fd)


def read_audio_vol():
    """AUDIO_VOL as the core holds it now (minicast's in-game menu writes it
    too); None when the LW bridge is in reset or the read fails."""
    try:
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    except OSError:
        return None
    try:
        m = mmap.mmap(fd, 4096, offset=RSTMGR_BASE)
        brg = struct.unpack_from("<I", m, RSTMGR_BRGMODRST)[0]
        m.close()
        if brg & 0x2:
            return None
        m = mmap.mmap(fd, 4096, offset=PVR_CFG_BASE)
        rev = struct.unpack_from("<I", m, PVR_REVISION)[0]
        v = struct.unpack_from("<I", m, PVR_AUDIO_VOL_R7 if rev >= 6
                               else PVR_AUDIO_VOL)[0]
        m.close()
        return v & 0x17
    except (OSError, ValueError):
        return None
    finally:
        os.close(fd)


# pad hotkeys while a game runs (held Start + button), from the mapped
# [inputN] buttons: Start+X volume up, Start+Y volume down, Start+L quit
HOTKEY_ROLES = {"ButtonStart": "start", "ButtonX": "up", "ButtonY": "down",
                "TriggerL": "quit"}


# evdev gamepad buttons: BTN_START, BTN_NORTH (X), BTN_WEST (Y), BTN_TL (L1),
# BTN_TL2 (L2 - DualSense/DS4 also report their analog L2 as this button)
HOTKEY_DEFAULTS = ((0x13b, "start"), (0x133, "up"), (0x134, "down"),
                   (0x136, "quit"), (0x138, "quit"))


# emulator builds with the in-game menu (Start+L / Start+Select opens it)
MENU_ELFS = ("minicast-crt-tacore-ra.elf",)


def pad_hotkey_codes(cfg):
    """{key code: role} from every [inputN] section's key: mappings."""
    codes = {}
    for section in cfg.sections():
        if not re.match(r"input\d+$", section):
            continue
        for name, role in HOTKEY_ROLES.items():
            m = re.match(r"key:(\d+)$", cfg.get(section, name, fallback="").strip())
            if m:
                codes.setdefault(int(m.group(1)), role)
    # roles with no saved button mapping (nothing configured yet, or L on an
    # analog trigger) fall back to the standard pad buttons, so a fresh setup
    # still has its hotkeys; explicitly mapped roles are left alone
    # only pad buttons (BTN_*, 0x100+) count: a keyboard key mapped to L
    # (E by default) must not leave a pad without its quit combo
    missing = set(HOTKEY_ROLES.values()) - set(
        r for c, r in codes.items() if c >= 0x100)
    for code, role in HOTKEY_DEFAULTS:
        if role in missing:
            codes.setdefault(code, role)
    return codes


# Logs live on the SD card: a hang or black screen usually ends in a power
# cycle, which would wipe /tmp and the evidence with it.
LOG_DIR = os.path.join(MINICAST_DIR, "logs")
CRT_LOG = os.path.join(LOG_DIR, "dreamster-crt.log")
MINICAST_LOG_DIR = os.path.join(LOG_DIR, "games")
PAD_RAW_LOG = os.path.join(LOG_DIR, "pad-raw.log")   # one log per game, newest wins


def crt_log(msg):
    try:
        if not os.path.isdir(LOG_DIR):
            os.makedirs(LOG_DIR, exist_ok=True)
        elif os.path.getsize(CRT_LOG) > 512 * 1024:     # keep one old copy
            os.replace(CRT_LOG, CRT_LOG + ".1")
    except OSError:
        pass
    try:
        with open(CRT_LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except OSError:
        pass


def usb_net_devices():
    """USB device dirs (with an 'authorized' switch) behind network interfaces."""
    devs = set()
    for n in glob.glob("/sys/class/net/*"):
        d = os.path.realpath(os.path.join(n, "device"))
        if "/usb" not in d:
            continue
        usbdev = os.path.dirname(d)             # .../1-1.7:1.2 -> .../1-1.7
        if os.path.exists(os.path.join(usbdev, "authorized")):
            devs.add(usbdev)
    return sorted(devs)


WIFI_WATCHDOG = [None]


def _hub_port_switch(usbdev):
    """sysfs 'disable' switch of the hub port a USB device hangs off
    (1-1.7 -> /sys/bus/usb/devices/1-1:1.0/1-1-port7/disable), or None."""
    name = os.path.basename(usbdev)
    if "." not in name:
        return None
    parent, port = name.rsplit(".", 1)
    sw = "/sys/bus/usb/devices/%s:1.0/%s-port%s/disable" % (parent, parent, port)
    return sw if os.path.exists(sw) else None


def _bt_pads_on(usbdev):
    """Names of input devices connected over a Bluetooth adapter that lives
    on this USB device (WiFi+BT combo dongles): switching the dongle off
    would drop those pads mid-game."""
    usbdev = os.path.realpath(usbdev) + "/"
    names = []
    for hci in glob.glob("/sys/class/bluetooth/hci*"):
        hdev = os.path.realpath(os.path.join(hci, "device"))
        if not (hdev + "/").startswith(usbdev):
            continue
        for ev in glob.glob("/sys/class/input/event*"):
            path = os.path.realpath(os.path.join(ev, "device"))
            if "/bluetooth/%s/" % os.path.basename(hci) in path:
                try:
                    with open(os.path.join(ev, "device", "name")) as f:
                        names.append(f.read().strip())
                except OSError:
                    names.append(os.path.basename(ev))
    return names


def wifi_pause():
    """Switch the dongle's hub port off (closest thing to unplugging it: the
    hub stops talking to it); fall back to de-authorizing the device.
    Returns [(switch_file, value_to_restore)]."""
    paused = []
    for d in usb_net_devices():
        bt = _bt_pads_on(d)
        if bt:
            crt_log("wifi left on: Bluetooth pads on the same dongle (%s)"
                    % ", ".join(bt))
            continue
        sw = _hub_port_switch(d)
        target = (sw, "1", "0") if sw else (os.path.join(d, "authorized"), "0", "1")
        try:
            with open(target[0], "w") as f:
                f.write(target[1])
            paused.append((target[0], target[2]))
        except OSError as e:
            crt_log("wifi pause failed on %s: %s" % (d, e))
    crt_log("wifi paused: %s" % (paused or "none"))
    if paused:
        # safety net: if this launcher dies without its cleanup (SIGKILL...),
        # a detached watchdog re-attaches the dongle so the box keeps WiFi
        cmd = ("while kill -0 %d 2>/dev/null; do sleep 2; done; " % os.getpid()
               + "".join("echo %s > '%s'; " % (v, f) for f, v in paused))
        try:
            with open(os.devnull, "rb+") as devnull:
                WIFI_WATCHDOG[0] = subprocess.Popen(
                    ["sh", "-c", cmd], stdin=devnull, stdout=devnull,
                    stderr=devnull, start_new_session=True)
        except OSError as e:
            crt_log("wifi watchdog failed: %s" % e)
    return paused


def wifi_resume(paused):
    wd = WIFI_WATCHDOG[0]
    if wd is not None:
        WIFI_WATCHDOG[0] = None
        try:
            wd.kill()
            wd.wait(1)
        except (OSError, subprocess.TimeoutExpired):
            pass
    for f_path, value in paused:
        try:
            with open(f_path, "w") as f:
                f.write(value)
        except OSError as e:
            crt_log("wifi resume failed on %s: %s" % (f_path, e))
    if paused:
        crt_log("wifi resumed")


class UinputKeys:
    """Tiny uinput keyboard so the launcher can press keys minicast reacts
    to on any device (ESC = save + exit). Must exist before minicast starts:
    it scans /dev/input once."""

    UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
    UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502

    def __init__(self, keys=(1,)):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, self.UI_SET_EVBIT, 1)
        for k in keys:
            fcntl.ioctl(self.fd, self.UI_SET_KEYBIT, k)
        name = b"dreamster-crt-keys".ljust(80, b"\0")
        os.write(self.fd, name + struct.pack("HHHHi", 0x06, 0x1209, 0xDC01, 1, 0)
                 + b"\0" * (4 * 64 * 4))
        fcntl.ioctl(self.fd, self.UI_DEV_CREATE)

    def _ev(self, typ, code, val):
        os.write(self.fd, struct.pack("llHHi", 0, 0, typ, code, val))

    def tap(self, code):
        self._ev(1, code, 1); self._ev(0, 0, 0)
        time.sleep(0.1)
        self._ev(1, code, 0); self._ev(0, 0, 0)

    def close(self):
        try:
            fcntl.ioctl(self.fd, self.UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


# ---- back to the game list after a game ----------------------------------
# The menu core (and MiSTer's video setup for it) is gone once the CRT
# bitstream is loaded, so instead of reloading it the launcher shows the
# Linux text console - where this menu draws - through the bitstream's own
# 15 kHz scanout: the PVR framebuffer registers point at a VRAM buffer and
# /dev/fb0 is copied into it in the Dreamcast split layout (32-bit FB word i
# at VRAM byte i*8, bank 0), a few times a second while the menu is up.
# Only ever started after a game has run (minicast brings the DDR ports up);
# a test without that hung the HPS. False = games return to the MiSTer menu.
RETURN_TO_LIST = True
PVR_REGS_BASE = 0xFF200000
PVR_FB_R_CTRL, PVR_FB_R_SOF1, PVR_VO_CONTROL = 0x044, 0x050, 0x0E8
PVR_VRAM_BASE = 0x00                      # in the PVR_CFG_BASE page
FB_SYS = "/sys/class/graphics/fb0"


def _read_sys(name):
    try:
        with open(os.path.join(FB_SYS, name)) as f:
            return f.read().strip()
    except OSError:
        return ""


class ConsoleMirror(threading.Thread):
    def __init__(self, width, height, stride):
        threading.Thread.__init__(self, daemon=True)
        self.w, self.h, self.stride = width, height, stride
        self.stop = threading.Event()
        self.mem_fd = self.fb_fd = None
        self.maps = []

    @classmethod
    def start_if_possible(cls):
        try:
            w, h = (int(v) for v in _read_sys("virtual_size").split(","))
            stride = int(_read_sys("stride"))
            bpp = int(_read_sys("bits_per_pixel"))
        except ValueError:
            crt_log("mirror: no fb0 geometry")
            return None
        # the scanout reads 32-bit 0888 at 640 (or 320 pixel-doubled) wide
        if bpp != 32 or w not in (640, 320) or h not in (240, 480) \
                or stride != w * 4:
            crt_log("mirror: unsupported console %dx%d/%d stride %d" % (w, h, bpp, stride))
            return None
        m = cls(w, h, stride)
        try:
            m.setup()
        except (OSError, ValueError) as e:
            crt_log("mirror: setup failed: %s" % e)
            m.close()
            return None
        m.start()
        return m

    def setup(self):
        self.mem_fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        rst = mmap.mmap(self.mem_fd, 4096, offset=RSTMGR_BASE)
        brg = struct.unpack_from("<I", rst, RSTMGR_BRGMODRST)[0]
        rst.close()
        if brg & 0x2:
            raise OSError("LW bridge in reset")
        cfgp = mmap.mmap(self.mem_fd, 4096, offset=PVR_CFG_BASE)
        self.maps.append(cfgp)
        vram = struct.unpack_from("<I", cfgp, PVR_VRAM_BASE)[0] & 0xFF000000
        rev = struct.unpack_from("<I", cfgp, PVR_REVISION)[0]
        struct.pack_into("<I", cfgp, PVR_AUDIO_VOL_R7 if rev >= 6 else PVR_AUDIO_VOL,
                         0x10)                                 # mute in the menu
        size = self.h * self.stride
        self.vram = mmap.mmap(self.mem_fd, (2 * size + 4095) & ~4095, offset=vram)
        self.maps.append(self.vram)
        self.fb_fd = os.open("/dev/fb0", os.O_RDONLY)
        try:
            self.fb = mmap.mmap(self.fb_fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
        except OSError as e:
            # 6.x fbdev refuses mmap on MiSTer_fb (no fb_mmap): read the
            # pixels where the driver says they are (FSCREENINFO smem_start)
            if e.errno not in (errno.ENODEV, errno.EINVAL):
                raise
            fix = bytearray(80)
            fcntl.ioctl(self.fb_fd, 0x4602, fix, True)   # FBIOGET_FSCREENINFO
            start = struct.unpack_from("I", fix, 16)[0]
            if not start:
                raise
            self.fb = mmap.mmap(self.mem_fd, size, mmap.MAP_SHARED,
                                mmap.PROT_READ, offset=start)
            crt_log("mirror: fb0 read through /dev/mem at 0x%08X" % start)
        self.maps.append(self.fb)
        self.dst = memoryview(self.vram).cast("I")[0:2 * (size // 4):2]
        self.src = memoryview(self.fb).cast("I")
        self.copy()
        regs = mmap.mmap(self.mem_fd, 4096, offset=PVR_REGS_BASE)
        # FB_R_CTRL: enable, line double for a 240-line console, 0888 32-bit
        struct.pack_into("<I", regs, PVR_FB_R_CTRL,
                         1 | (2 if self.h == 240 else 0) | (3 << 2))
        struct.pack_into("<I", regs, PVR_FB_R_SOF1, 0)
        struct.pack_into("<I", regs, PVR_VO_CONTROL, (1 << 8) if self.w == 320 else 0)
        regs.close()
        crt_log("mirror: console %dx%d on VRAM 0x%08X" % (self.w, self.h, vram))

    def copy(self):
        self.dst[:] = self.src

    def run(self):
        last = None
        while not self.stop.wait(0.08):
            try:
                d = DISPLAY[0]
                # the pixel UI counts its redraws; the text console has to
                # be compared (a full fb0 read)
                snap = ("frames", d.frames) if d is not None else self.fb[:]
                if snap != last:
                    self.copy()
                    last = snap
            except (OSError, ValueError):
                break

    def close(self):
        self.stop.set()
        if self.is_alive():
            self.join(1)
        # stop the scanout's DDR reads before anyone reloads the FPGA: a
        # bitstream swap mid-transaction can leave the f2sdram port wedged
        # (the next game then shows corrupted fetches until a reboot)
        if self.mem_fd is not None:
            try:
                regs = mmap.mmap(self.mem_fd, 4096, offset=PVR_REGS_BASE)
                struct.pack_into("<I", regs, PVR_FB_R_CTRL, 0)
                regs.close()
                time.sleep(0.05)                 # > 2 frames at 60 Hz
            except (OSError, ValueError):
                pass
        for v in ("dst", "src"):
            mv = getattr(self, v, None)
            if mv is not None:
                mv.release()
        for m in self.maps:
            try:
                m.close()
            except (BufferError, ValueError):
                pass
        for fd in (self.fb_fd, self.mem_fd):
            if fd is not None:
                os.close(fd)
        self.maps, self.fb_fd, self.mem_fd = [], None, None



PVR_CRT_CTRL = 0x34


def effective_vfilter(cfg, mode):
    """The vertical filter a video mode really gets (Auto resolved)."""
    filt = VFILTER_OPT.current(cfg)
    if filt == "auto":
        filt = "smooth" if mode.startswith("480i") else "off"
    return filt


def crt_ctrl_value(cfg, mode):
    field = 1 if FIELD_OPT.current(cfg) == "correct" else 0
    filt = effective_vfilter(cfg, mode)
    # [3] 240p on the run-time-switchable (LINE_MODE 3) bitstream; the
    # fixed-mode builds ignore it
    p240 = 8 if mode.startswith("240p") else 0
    # [4] YPbPr on the analog pins (YPbPr-capable bitstream only)
    ypbpr = 16 if ANALOG_OPT.current(cfg) == "ypbpr" else 0
    return (field | p240 | ypbpr
            | {"off": 0, "light": 1 << 1, "smooth": 2 << 1}.get(filt, 0))


def write_crt_ctrl(value):
    """Poke CRT_CTRL, only while the LW bridge is out of reset (else SIGBUS)."""
    try:
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    except OSError:
        return False
    try:
        m = mmap.mmap(fd, 4096, offset=RSTMGR_BASE)
        brg = struct.unpack_from("<I", m, RSTMGR_BRGMODRST)[0]
        m.close()
        if brg & 0x2:
            return False
        m = mmap.mmap(fd, 4096, offset=PVR_CFG_BASE)
        struct.pack_into("<I", m, PVR_CRT_CTRL, value & 0x3F)
        m.close()
        return True
    except (OSError, ValueError):
        return False
    finally:
        os.close(fd)


class VolumeKeys(threading.Thread):
    """While minicast runs: re-apply the volume once the bridge is up,
    follow keyboard VolumeUp/VolumeDown/Mute keys (MiSTer 6 dB steps) and
    the pad hotkeys (Start+X/Y volume, Start+L quit the game)."""

    def __init__(self, att, pad_codes=None, esc=None):
        threading.Thread.__init__(self, daemon=True)
        self.esc = esc                 # UinputKeys, created before minicast
        self.att = att
        self.changed = False
        self.stop = threading.Event()
        self.pad_codes = pad_codes or {}
        self.proc = None               # minicast Popen, for Start+L

    def _step(self, what):
        # start from what the core has: the in-game menu may have changed it
        cur = read_audio_vol()
        if cur is not None:
            self.att = cur
        lvl, mute = self.att & 0x7, self.att & 0x10
        if what == "mute":
            mute ^= 0x10
        elif what == "up":
            lvl, mute = max(lvl - 1, 0), 0
        else:
            lvl, mute = min(lvl + 1, 7), 0
        self.att = lvl | mute
        self.changed = True
        write_audio_vol(self.att)

    def quit_game(self):
        """SIGTERM first: minicast-crt catches it, saves the flash and exits
        without touching the console. The ESC key (minicast's own exit, but
        it also lands on the tty the game list is drawn on) and SIGKILL are
        only fallbacks."""
        p = self.proc
        if p is None or p.poll() is not None:
            return
        crt_log("Start+L: quitting (SIGTERM)")
        p.send_signal(signal.SIGTERM)
        for _ in range(15):
            if p.poll() is not None:
                crt_log("exited on SIGTERM")
                return
            time.sleep(0.1)
        if self.esc:
            crt_log("SIGTERM ignored, pressing ESC")
            self.esc.tap(1)                         # KEY_ESC
            for _ in range(20):
                if p.poll() is not None:
                    return
                time.sleep(0.1)
        crt_log("still running, killing")
        p.kill()

    def run(self):
        start = time.time()
        deadline, applied = start + 20, False
        start_held = {}
        fds = []
        names = {}
        for path in glob.glob("/dev/input/event*"):
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            try:
                raw_name = fcntl.ioctl(fd, EVIOCGNAME(256), b"\0" * 256)
                noisy = _noisy_node(raw_name.split(b"\0", 1)[0].decode(errors="replace"))
            except OSError:
                noisy = False
            if noisy:        # sensor nodes: no keys, ~1000 events/s
                os.close(fd)
                continue
            fds.append(fd)
            names[fd] = os.path.basename(path)
        # every key event the kernel delivers during the game, on the same
        # clock as minicast's input trace (debugging latched directions)
        try:
            raw = open(PAD_RAW_LOG, "w", buffering=1)
        except OSError:
            raw = None
        try:
            while not self.stop.is_set():
                if not applied and time.time() - start > 2:
                    applied = write_audio_vol(self.att) or time.time() > deadline
                r = select.select(fds, [], [], 1.0)[0] if fds else []
                if not fds:
                    self.stop.wait(1.0)
                for fd in r:
                    try:
                        data = os.read(fd, 16 * 32)
                    except OSError:
                        continue
                    for i in range(0, len(data) - 15, 16):
                        _, _, typ, code, val = struct.unpack_from("llHHi", data, i)
                        if typ == 0 and code == 3 and raw:     # SYN_DROPPED
                            raw.write("%.3f %s SYN_DROPPED\n" % (
                                time.clock_gettime(time.CLOCK_MONOTONIC), names.get(fd)))
                        if typ != 1:
                            continue
                        if raw and val != 2:
                            raw.write("%.3f %s key %d %d\n" % (
                                time.clock_gettime(time.CLOCK_MONOTONIC),
                                names.get(fd), code, val))
                        if val == 1 and code in VOL_KEYS:
                            self._step(VOL_KEYS[code])
                        role = self.pad_codes.get(code)
                        if role and val == 1:
                            crt_log("pad %s (code %d) start_held=%s"
                                    % (role, code, bool(start_held.get(fd))))
                        if role == "start":
                            start_held[fd] = val != 0
                        elif role and val == 1 and start_held.get(fd):
                            if role == "quit":
                                self.quit_game()
                            else:
                                self._step(role)
        finally:
            for fd in fds:
                os.close(fd)
            if raw:
                raw.close()


# ---- profiling (debug) -------------------------------------------------------
# With minicast/profile.on present, the emulator writes its jit symbol maps and
# perf samples the whole process (cpu-clock: the PMU counters have no usable
# interrupt here). Everything lands in /tmp/prof, tmpfs, so the map's
# per-block flushes stay off the SD card.
PROFILE_FLAG = os.path.join(MINICAST_DIR, "profile.on")
PROFILE_DIR = "/tmp/prof"
PERF_BIN = os.path.join(MINICAST_DIR, "perf")


def profile_env():
    shutil.rmtree(PROFILE_DIR, ignore_errors=True)
    os.makedirs(PROFILE_DIR, exist_ok=True)
    env = dict(os.environ)
    env["MINICAST_PERF_MAP"] = os.path.join(PROFILE_DIR, "jit.map")
    env["MINICAST_SHOP_MAP"] = os.path.join(PROFILE_DIR, "shop.map")
    return env


def profile_start(pid, elf):
    try:
        with open(os.path.join(PROFILE_DIR, "info"), "w") as f:
            f.write("pid %d\nelf %s\n" % (pid, elf))
        return subprocess.Popen(
            # system-wide: both cores, so the ta consumer / audio thread on
            # cpu0 are seen too (-p missed them); stopped with SIGINT on exit
            [PERF_BIN, "record", "-e", "cpu-clock", "-F", "999", "-a",
             "-o", os.path.join(PROFILE_DIR, "perf.data")],
            stdout=subprocess.DEVNULL,
            stderr=open(os.path.join(PROFILE_DIR, "perf.log"), "w"))
    except OSError as e:
        crt_log("perf unavailable: %s" % e)
        return None


def profile_stop(prof):
    if prof is None:
        return
    try:
        prof.wait(timeout=1)
    except subprocess.TimeoutExpired:
        prof.send_signal(signal.SIGINT)
        try:
            prof.wait(timeout=10)
        except subprocess.TimeoutExpired:
            prof.kill()
    crt_log("perf profile saved in %s" % PROFILE_DIR)


# Present while a game runs at 1.2 GHz; still there at the next launch means
# that run never came back (froze / was power-cycled), so 1.2 GHz is dropped
# to 1 GHz wherever it was set.
OC12_MARKER = os.path.join(SYSTEM_DIR, "dreamster-oc12-running")


def _oc12_guard(cfg):
    if not os.path.exists(OC12_MARKER):
        return
    try:
        os.remove(OC12_MARKER)
    except OSError:
        pass
    if OVERCLOCK_OPT.current(cfg) != "2":
        return
    crt_log("last 1.2 GHz run did not exit cleanly: overclock back to 1 GHz")
    cfg.per_game = cfg.is_overridden(OVERCLOCK_OPT.section, OVERCLOCK_OPT.key)
    OVERCLOCK_OPT.set(cfg, "1")
    save_cfg(cfg)
    cfg.per_game = False


def select_bitstream(cfg):
    """(video mode, bitstream, notes) a launch with these settings uses."""
    notes = []
    mode = VIDEO_OPT.current(cfg)
    rbf = CRT_BITSTREAMS.get(mode, BITSTREAM_RBF)
    if ANALOG_OPT.current(cfg) == "ypbpr":
        # only the unified build sends YPbPr; it does 240p and 480i
        if os.path.exists(YPBPR_RBF):
            rbf = YPBPR_RBF
        else:
            notes.append("unified bitstream missing - analog output will be RGB")
    if CRT_CLOCK_OPT.current(cfg) == "100":
        # 100 MHz: the unified design built with a 75 / 100 MHz PLL (240p and
        # 480i, shadows, RGB / YPbPr) - whatever the video mode picked above
        if os.path.exists(UNIFIED_100_RBF):
            rbf = UNIFIED_100_RBF
        else:
            notes.append("100 MHz bitstream missing - it would run at 112.5 MHz")
    if not os.path.exists(rbf):
        notes.append("%s bitstream missing, using 240p" % mode)
        mode, rbf = "240p", CRT_BITSTREAMS["240p"]
    return mode, rbf, notes


# how the last emulator run ended: (exit code or None, seconds it ran)
LAST_RUN = [None, 0.0]
# an abnormal exit sooner than this = the emulator died while starting up
EARLY_CRASH_SECS = 15


def early_crash():
    rc, secs = LAST_RUN
    return rc != 0 and secs < EARLY_CRASH_SECS


def launch(game, overclock, cfg=None):
    cfg = effective_cfg(game, base=cfg if not isinstance(cfg, GameCfg) else cfg.base)
    _oc12_guard(cfg)
    oc_step = OVERCLOCK_OPT.current(cfg)
    overclock = oc_step in ("1", "2")
    oc_khz = "1200000" if oc_step == "2" else "1000000"
    if cfg.has_overrides():
        crt_log("per-game settings: %s" % game_cfg_path(game))
    mode, rbf, notes = select_bitstream(cfg)
    for note in notes:
        print(note)
    crt_log("bitstream %s" % os.path.basename(rbf))
    if not (os.path.exists(rbf) and os.path.exists(HDMI15K)):
        print("CRT bitstream or hdmi15k.py missing - refusing to launch (would not be 15 kHz)")
        return
    print("\n=== %s ===" % TITLE)
    print("Launching: %s\n" % game)

    basename = os.path.basename(game).split('.')[0]
    dirname = os.path.dirname(game)
    with open("/tmp/FILESELECT", "w") as text_file:
        print(f"selected", file=text_file)
    with open("/tmp/CURRENTPATH", "w") as text_file:
        print(f"{basename}", file=text_file)
    with open("/tmp/FULLPATH", "w") as text_file:
        print(f"{dirname}", file=text_file)

    prev_gov = None
    if overclock:
        prev_gov = _cpufreq_read("scaling_governor")
        print("overclock: CPU -> %d MHz, governor -> performance" % (int(oc_khz) // 1000))
        if oc_step == "2":
            try:
                _write_file_synced(OC12_MARKER, game + "\n")
            except OSError:
                pass
        _cpufreq_prepare()
        _cpufreq_write("scaling_max_freq", oc_khz)
        _cpufreq_write("scaling_governor", "performance")
        crt_log("overclock: %s kHz" % _cpufreq_read("scaling_cur_freq"))

    if cfg is None:
        cfg = load_cfg()
    elf = MINICAST_ELF
    fast = os.path.join(MINICAST_DIR, "minicast-crt-tacore.elf")
    fasttrace = os.path.join(MINICAST_DIR, "minicast-crt-tacore-trace.elf")
    perf = os.path.join(MINICAST_DIR, "minicast-crt-tacore-perf.elf")
    if CRT_EMU_OPT.current(cfg) == "fasttrace" and os.path.exists(fasttrace):
        fast = fasttrace
    elif CRT_EMU_OPT.current(cfg) == "perf" and os.path.exists(perf):
        fast = perf
    audiothr = os.path.join(MINICAST_DIR, "minicast-crt-tacore-audiothr.elf")
    if CRT_EMU_OPT.current(cfg) == "audiothr" and os.path.exists(audiothr):
        fast = audiothr
    ra_elf = os.path.join(MINICAST_DIR, "minicast-crt-tacore-ra.elf")
    if CRT_EMU_OPT.current(cfg) == "ra" and os.path.exists(ra_elf):
        fast = ra_elf
    if CRT_EMU_OPT.current(cfg) in ("fast", "fasttrace", "perf", "audiothr", "ra") and os.path.exists(fast):
        elf = fast
        # the r6b-only dynarec passes are off unless enabled in emu.cfg
        c = load_cfg()
        changed = False
        for key in ("Dynarec.opt_anchored_loops", "Dynarec.opt_self_loops"):
            if c.get("config", key, fallback="") != "yes":
                c.set("config", key, "yes")
                changed = True
        if changed:
            save_cfg(c)
    trace = os.path.join(MINICAST_DIR, "minicast-crt-trace.elf")
    if CRT_EMU_OPT.current(cfg) == "trace" and os.path.exists(trace):
        elf = trace
    crt_log("emulator %s" % os.path.basename(elf))
    # minicast only drives pads that have an [inputN] section; a pad never
    # opened in the mapper (a new DualSense, or the same one over Bluetooth -
    # a different id) would sit dead in game while working in these menus.
    # Save the default mapping for any such pad, as the mapper would.
    try:
        c = load_cfg()
        load_input_config(c)
        devs = scan_devices()
        new = [d for d in devs if d.id not in CONFIG and default_config(d)]
        if new:
            save_input_config(c, devs)
            crt_log("default mapping saved for %s" % ", ".join(
                "%s [%s]" % (d.name, d.id) for d in new))
            # the menu's in-memory cfg (saved on its next edit) must carry
            # the new sections too, or that save would drop them again
            base = cfg.base if isinstance(cfg, GameCfg) else cfg
            for sec in list(base.sections()):
                if re.match(r"input\d+$", sec):
                    base.remove_section(sec)
            for sec in c.sections():
                if re.match(r"input\d+$", sec):
                    base.add_section(sec)
                    for k, v in c.items(sec):
                        base.set(sec, k, v)
    except Exception as e:           # never block a launch over this
        crt_log("pad auto-mapping failed: %s" % e)
    undo_overrides = _apply_overrides(cfg.over)
    clk_opt = CRT_CLOCK_OPT.current(cfg)
    # "100" = the 75/100 MHz bitstream's fast slot (ClockSel 2 on that file)
    prev_clk = _force_clocksel("2" if clk_opt == "100" else clk_opt)
    try:
        esc = UinputKeys()
    except OSError as e:
        esc = None
        crt_log("uinput unavailable: %s" % e)
    codes = pad_hotkey_codes(cfg)
    # builds with the in-game menu take Start+L themselves (it opens the
    # menu, whose Exit Game / Exit Emulator replace the quit shortcut)
    if os.path.basename(elf) in MENU_ELFS:
        codes = {c: r for c, r in codes.items() if r != "quit"}
    crt_log("launch %s hotkeys=%s" % (game, codes))
    vol = VolumeKeys(crt_volume_att(cfg), codes, esc)
    wifi_paused = []
    prof = None
    try:
        run(["insmod", MEM_WC], cwd=MINICAST_DIR)
        run([LOAD_BITSTREAM, rbf], cwd=MINICAST_DIR)
        run([SETUP_HDMI], cwd=MINICAST_DIR)
        run(["python3", HDMI15K] + (["--240p"] if mode.startswith("240p") else []),
            cwd=MINICAST_DIR)
        write_audio_vol(vol.att)
        ctrl = crt_ctrl_value(cfg, mode)
        write_crt_ctrl(ctrl)
        crt_log("CRT_CTRL = 0x%x (%s)" % (ctrl, mode))
        if WIFI_OPT.current(cfg) == "pause":
            wifi_paused = wifi_pause()
        vol.start()
        print("+ " + elf + " " + game)
        sys.stdout.flush()
        # minicast's per-frame stats go to a log, not the console the game
        # list is later mirrored from (keeps that screen clean)
        os.makedirs(MINICAST_LOG_DIR, exist_ok=True)
        # one log per session (date_time_game_emulator), newest 20 kept, so
        # runs can be compared afterwards
        log_name = "%s_%s_%s" % (
            time.strftime("%Y%m%d_%H%M%S"),
            re.sub(r"[^A-Za-z0-9]+", "_", os.path.basename(game).rsplit(".", 1)[0]),
            os.path.basename(elf).replace("minicast-crt-", "").rsplit(".", 1)[0])
        try:
            old = sorted(glob.glob(os.path.join(MINICAST_LOG_DIR, "*.log")))
            for f in old[:-19]:
                os.remove(f)
        except OSError:
            pass
        if game != "nodisk" and VMU_OPT.current(cfg) == "game":
            vmu_swap_in(game)
        env = None
        # (its own flag: env also carries the RA switches below, and used
        # to start perf on every dry-run launch)
        profiling = os.path.exists(PROFILE_FLAG)
        if profiling:
            env = profile_env()
        ra_mode = RA_OPT.current(cfg)
        if ra_mode in ("off", "dryrun"):
            env = dict(env if env is not None else os.environ)
            env["MINICAST_RA" if ra_mode == "off" else "MINICAST_RA_DRYRUN"] = (
                "0" if ra_mode == "off" else "1")
        popups = RA_POPUPS_OPT.current(cfg)
        if popups in ("on", "off"):
            env = dict(env if env is not None else os.environ)
            env["MINICAST_RA_POPUPS"] = "1" if popups == "on" else "0"
        crt_log("retroachievements: %s, popups %s" % (ra_mode, popups))
        LAST_RUN[:] = [None, 0.0]
        started = time.monotonic()
        with open(os.path.join(MINICAST_LOG_DIR, log_name + ".log"), "w") as logf:
            vol.proc = subprocess.Popen([elf, game], cwd=MINICAST_DIR, env=env,
                                        stdout=logf, stderr=subprocess.STDOUT)
        if profiling:
            prof = profile_start(vol.proc.pid, elf)
        vol.proc.wait()
        LAST_RUN[:] = [vol.proc.returncode, time.monotonic() - started]
    finally:
        profile_stop(prof)
        vmu_swap_out()
        vol.stop.set()
        wifi_resume(wifi_paused)
        crt_log("minicast exited (%s)" % (vol.proc.returncode if vol.proc else "not started"))
        if esc:
            esc.close()
        if prev_clk is not None:
            _force_clocksel(prev_clk)
        _restore_overrides(undo_overrides)
        if vol.changed and not options_changed_has("volume"):
            # keep the level picked with the volume keys for next time
            # (a volume from the in-game menu wins: apply_options_changed)
            c = load_cfg()
            CRT_VOL_OPT.set(c, "mute" if vol.att & 0x10 else str(vol.att & 0x7))
            save_cfg(c)
        try:
            os.remove(OC12_MARKER)
        except OSError:
            pass
        if overclock:
            print("overclock: restoring CPU to 800 MHz")
            _cpufreq_write("scaling_max_freq", "800000")
            try:
                with open(CPUFREQ_BOOST, "w") as f:
                    f.write("0")
            except OSError:
                pass
            if prev_gov:
                _cpufreq_write("scaling_governor", prev_gov)


# ---- emulator <-> launcher protocol ----------------------------------------
# The emulator's in-game menu (Start+Select / Start+R) can switch games,
# change a few options and quit DreamSTer. Files in IPC_DIR (tmpfs):
#   games.json          launcher -> emulator, before each launch:
#                       {"games": [{"name", "path"}, ...], "current": path}
#                       (names as in the game list; current "" = BIOS)
#   options.json        launcher -> emulator, before each launch: the values
#                       in effect, "auto" resolved - {"volume": "0".."7" |
#                       "mute", "vfilter": off|light|smooth, "field":
#                       correct|original, "popups": on|off}
#   options_changed.json  emulator -> launcher, on exit: options the menu
#                       changed (same keys); persisted to emu.cfg - to the
#                       game's own file for keys the game overrides, else
#                       globally
#   request.json        emulator -> launcher, on exit: {"action": "load",
#                       "path": P} launches P right away, {"action": "list"}
#                       (in-game Exit Game) returns to the game list, {"action": "exit"}
#                       leaves DreamSTer; none = back to the game list
# Written atomically (temp file + rename); stale emulator files are removed
# before each launch.
IPC_DIR = "/tmp/dreamster"
IPC_GAMES, IPC_OPTIONS = "games.json", "options.json"
IPC_CHANGED, IPC_REQUEST = "options_changed.json", "request.json"
RA_CFG_PATH = "/media/fat/retroachievements.cfg"


def _ipc_path(name):
    return os.path.join(IPC_DIR, name)


def _write_json_atomic(path, obj):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, path)


def _take_json(name):
    """Reads and removes an emulator file; None if absent or unreadable."""
    path = _ipc_path(name)
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        crt_log("ipc: bad %s: %s" % (name, e))
        data = None
    try:
        os.remove(path)
    except OSError:
        pass
    return data


def options_changed_has(key):
    """Whether the emulator's options_changed.json carries a valid `key`
    (read only; apply_options_changed() consumes the file)."""
    try:
        with open(_ipc_path(IPC_CHANGED)) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    return (isinstance(data, dict) and key in data
            and _norm_option(key, data[key]) is not None)


def list_path(game, games):
    """`game` spelled exactly like its game list entry (the emulator matches
    games.json's "current" against the entries by string); unchanged when
    it isn't in the list."""
    paths = [p for _, p in games]
    if game in paths:
        return game
    real = os.path.realpath(game)
    for p in paths:
        if os.path.realpath(p) == real:
            return p
    return game


def ra_cfg_popups(path=None):
    """retroachievements.cfg dreamster_popups, read the way minicast does
    (key before '=' compared case-insensitively, atoi value, default on)."""
    on = True
    try:
        with open(path or RA_CFG_PATH, errors="replace") as f:
            for line in f:
                line = line.rstrip("\r\n")
                if not line or line[0] == "#" or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                if key.lower() == "dreamster_popups":
                    m = re.match(r"\s*([+-]?\d+)", val)
                    on = bool(m and int(m.group(1)))
    except OSError:
        pass
    return on


def emulator_options(game):
    """options.json: the values a launch of `game` runs with."""
    cfg = effective_cfg(game)
    mode, _, _ = select_bitstream(cfg)
    att = crt_volume_att(cfg)
    popups = RA_POPUPS_OPT.current(cfg)
    if popups not in ("on", "off"):
        popups = "on" if ra_cfg_popups() else "off"
    return {"volume": "mute" if att & 0x10 else str(att & 0x7),
            "vfilter": effective_vfilter(cfg, mode),
            "field": FIELD_OPT.current(cfg),
            "popups": popups}


def write_launch_ipc(game, games):
    """games.json + options.json for the emulator; stale answers removed.
    Never blocks a launch."""
    try:
        os.makedirs(IPC_DIR, exist_ok=True)
        for name in (IPC_REQUEST, IPC_CHANGED):
            try:
                os.remove(_ipc_path(name))
            except FileNotFoundError:
                pass
        _write_json_atomic(_ipc_path(IPC_GAMES), {
            "games": [{"name": name, "path": path} for name, (_, path)
                      in zip(display_names(games), games)],
            "current": "" if game == "nodisk" else game})
        _write_json_atomic(_ipc_path(IPC_OPTIONS), emulator_options(game))
    except Exception as e:
        crt_log("ipc: launch files not written: %s" % e)


def _norm_option(key, raw):
    """(Option, cfg value) for one options_changed entry, or None."""
    v = raw if isinstance(raw, bool) else str(raw).strip().lower()
    if key == "volume":
        if v == "mute" or (v in [str(n) for n in range(8)]):
            return CRT_VOL_OPT, v
    elif key == "vfilter":
        if v in ("off", "light", "smooth", "auto"):
            return VFILTER_OPT, v
    elif key == "field":
        if v in ("correct", "original"):
            return FIELD_OPT, v
    elif key == "popups":
        if v in (True, "on", "1", "true", "yes"):
            return RA_POPUPS_OPT, "on"
        if v in (False, "off", "0", "false", "no"):
            return RA_POPUPS_OPT, "off"
    return None


def apply_options_changed(game):
    """Persists what the in-game menu changed; returns {cfg key: value}."""
    data = _take_json(IPC_CHANGED)
    if not isinstance(data, dict):
        return {}
    changes = []
    for key, raw in data.items():
        norm = _norm_option(key, raw)
        if norm is None:
            crt_log("ipc: ignoring option %s=%r" % (key, raw))
        else:
            changes.append(norm)
    if not changes:
        return {}
    gcfg = effective_cfg(game)
    for opt, value in changes:
        # a key this game overrides stays per game (a global change would be
        # invisible for it); everything else is the global setting
        gcfg.per_game = gcfg.is_overridden(opt.section, opt.key)
        opt.set(gcfg, value)
    gcfg.per_game = False
    save_cfg(gcfg)
    done = dict((opt.key, value) for opt, value in changes)
    crt_log("in-game menu changed %s" % done)
    return done


def take_request():
    """The emulator's request: ("load", path), ("exit",) or None."""
    data = _take_json(IPC_REQUEST)
    if not isinstance(data, dict):
        return None
    action = data.get("action")
    if action == "list":             # in-game "Exit Game": back to the list
        return None
    if action == "exit":
        return ("exit",)
    if action == "load":
        path = data.get("path")
        if isinstance(path, str) and (path == "nodisk" or os.path.isfile(path)):
            return ("load", path)
        crt_log("ipc: load request for a missing game: %r" % (path,))
        return None
    crt_log("ipc: unknown request %r" % (data,))
    return None


def game_title(game, games):
    if game == "nodisk":
        return "Dreamcast BIOS"
    for name, (_, path) in zip(display_names(games), games):
        if path == game:
            return name
    return os.path.basename(game)


def play(game, games):
    """Runs a game, then whatever the emulator's in-game menu asked for on
    the way out: the next game straight away, or leaving DreamSTer.
    Returns "exit", or None to go back to the game list."""
    while True:
        if game != "nodisk":
            game = list_path(game, games)   # e.g. a --launch argument
        cfg = load_cfg()
        overclock = cfg.get("dreamster", "Overclock",
                            fallback="0").strip() == "1"
        write_launch_ipc(game, games)
        pixel_notice("Starting", [game_title(game, games), "",
                                  "Loading the emulator..."])
        launch(game, overclock, cfg)
        if early_crash():
            # the game never got going: mirroring the list into VRAM now
            # hangs the HPS (only safe after a game ran), so leave to the
            # MiSTer menu instead
            crt_log("emulator crashed at start-up (%s after %.1f s), "
                    "back to the MiSTer menu" % tuple(LAST_RUN))
            return "exit"
        try:
            apply_options_changed(game)
            req = take_request()
        except Exception as e:           # never strand the user over this
            crt_log("ipc: after-game handling failed: %s" % e)
            req = None
        if req is None:
            return None
        if req[0] == "exit":
            crt_log("in-game menu: exit DreamSTer")
            return "exit"
        crt_log("in-game menu: load %s" % req[1])
        game = req[1]


# ---- quick launch from MiSTer's main menu --------------------------------
# Same trick as MisterZine: an .mgl that "loads" the menu core under a
# unique set name (<rbf>menu</rbf><setname>dcq_xxxxxxxx</setname>). Main
# writes that name to /tmp/CORENAME; minicast/dcwatch.py (started from
# linux/user-startup.sh) sees it and runs `DreamSTer.sh --launch <game>`.
QUICK_DIR = "/media/fat/_Dreamcast"
QUICK_MAP = os.path.join(MINICAST_DIR, "quicklaunch.json")
QUICK_MARK = "<!-- DreamSTer quick launch -->"


def _quick_id(path):
    import zlib
    return "dcq_%08x" % (zlib.crc32(path.encode("utf-8")) & 0xFFFFFFFF)


def sync_menu():
    """(Re)write _Dreamcast/<game>.mgl for every game, plus a BIOS entry."""
    import json
    cfg = load_cfg()
    games = scan_games(resolve_game_dirs(cfg))
    os.makedirs(QUICK_DIR, exist_ok=True)
    entries = [("Dreamcast BIOS", "nodisk")]
    entries += [(os.path.splitext(os.path.basename(path))[0], path) for _, path in games]
    mapping, wanted, used = {}, set(), set()
    for title, path in entries:
        sid = "dcq_bios" if path == "nodisk" else _quick_id(path)
        name = re.sub(r'[\\/:*?"<>|]', "_", title).strip() or sid
        base, n = name, 2
        while name.lower() in used:
            name, n = "%s (%d)" % (base, n), n + 1
        used.add(name.lower())
        fn = name + ".mgl"
        wanted.add(fn)
        mapping[sid] = path
        body = ("<mistergamedescription>\n\t%s\n\t<rbf>menu</rbf>\n"
                "\t<setname>%s</setname>\n</mistergamedescription>\n" % (QUICK_MARK, sid))
        dst = os.path.join(QUICK_DIR, fn)
        try:
            with open(dst) as f:
                if f.read() == body:
                    continue
        except OSError:
            pass
        with open(dst, "w") as f:
            f.write(body)
    for fn in os.listdir(QUICK_DIR):          # drop entries of removed games
        if fn.endswith(".mgl") and fn not in wanted:
            dst = os.path.join(QUICK_DIR, fn)
            try:
                with open(dst) as f:
                    ours = QUICK_MARK in f.read()
            except OSError:
                ours = False
            if ours:
                os.remove(dst)
    with open(QUICK_MAP, "w") as f:
        json.dump(mapping, f, indent=1)
    print("quick launch: %d entries in %s" % (len(mapping), QUICK_DIR))


def main():
    # MiSTer launches Scripts-menu entries pinned to core 1 via taskset;
    # widen our affinity to both cores so minicast (and children) get core 0+1.
    try:
        os.sched_setaffinity(0, {0, 1})
    except OSError:
        pass

    # actually, i like terminating via sigint ~ skmp
    # signal.signal(signal.SIGINT, signal.SIG_IGN)

    # Take the box over up front: with MiSTer gone the console keyboard only
    # reaches us through the tty and gamepads are free for the nav pump.
    # Whatever happens after this point, MiSTer comes back on exit.
    def _exit_on_signal(signum, frame):
        raise SystemExit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _exit_on_signal)

    if len(sys.argv) > 1 and sys.argv[1] == "--sync-menu":
        sync_menu()
        return

    try:
        os.makedirs(LOG_DIR, exist_ok=True)
    except OSError:
        pass
    detect_parent_mister()
    kill_mister()
    recover_overrides()
    vmu_swap_out()          # a game that never came back still owns vmu A1

    if len(sys.argv) > 2 and sys.argv[1] == "--launch":
        # quick launch: straight into the game with the saved settings (and
        # any game the in-game menu switches to), back to MiSTer's menu when
        # it exits
        try:
            try:
                games = scan_games(resolve_game_dirs(load_cfg()))
            except Exception as e:
                crt_log("quick launch: game scan failed: %s" % e)
                games = []
            play(sys.argv[2], games)
        finally:
            restart_mister()
        return

    os.environ.setdefault("TERM", "linux")    # scripts start without TERM
    if open_display() is None:
        text_console()
    mirror = None
    try:
        while True:
            try:
                game = run_ui()
            except Exception:
                if DISPLAY[0] is None:
                    raise
                # a pixel UI failure must not cost the session: log it and
                # carry on with the text UI
                import traceback
                crt_log("pixel ui failed, switching to curses:\n%s"
                        % traceback.format_exc())
                close_display()
                text_console()
                game = run_ui()
            if mirror:
                mirror.close()
                mirror = None
            if game is None:
                break
            if play(game, list(GAME_LIST)) == "exit":
                break
            # back to the game list, shown through the CRT bitstream; if the
            # console can't be mirrored, fall back to the MiSTer menu
            mirror = ConsoleMirror.start_if_possible() if RETURN_TO_LIST else None
            if mirror is None:
                break
    finally:
        if mirror:
            mirror.close()
        close_display()
        try:
            sync_menu()          # keep the _Dreamcast menu entries current
        except Exception as e:
            print("quick launch sync failed: %s" % e)
        restart_mister()


if __name__ == "__main__":
    main()
