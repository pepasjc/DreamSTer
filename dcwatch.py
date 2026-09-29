#!/usr/bin/env python3
"""DreamSTer quick launch watcher (started from linux/user-startup.sh).

The _Dreamcast/<game>.mgl entries in MiSTer's main menu "load" the menu core
under a set name dcq_xxxxxxxx; Main then writes that name to /tmp/CORENAME.
When one shows up, run DreamSTer straight into the mapped game. Refreshes the
menu entries at start so newly added games appear after a reboot.
"""
import json
import os
import subprocess
import time

LAUNCHER = "/media/fat/Scripts/DreamSTer.sh"
QUICK_MAP = "/media/fat/minicast/quicklaunch.json"
CORENAME = "/tmp/CORENAME"
LOG = "/tmp/dreamster-quick.log"


def log(msg):
    with open(LOG, "a") as f:
        f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


GAME_DIRS = ["/media/fat/games/Dreamcast"] + [
    "/media/usb%d/games/Dreamcast" % i for i in range(8)]
SCAN_EVERY = 5


def games_stamp():
    """mtimes of the game dirs and their direct subfolders (cheap)."""
    out = []
    for d in GAME_DIRS:
        try:
            out.append((d, os.stat(d).st_mtime))
            for e in os.scandir(d):
                if e.is_dir():
                    out.append((e.path, e.stat().st_mtime))
        except OSError:
            pass
    return out


def main():
    if not os.path.exists(LAUNCHER):
        return
    time.sleep(5)                                   # let the SD card settle
    subprocess.call(["python3", LAUNCHER, "--sync-menu"],
                    stdout=open(LOG, "a"), stderr=subprocess.STDOUT)
    last = read(CORENAME)
    stamp, next_scan = games_stamp(), time.time() + SCAN_EVERY
    while True:
        time.sleep(0.3)
        if time.time() >= next_scan:
            # new/removed games: game folders change the top-level mtime
            next_scan = time.time() + SCAN_EVERY
            now = games_stamp()
            if now != stamp:
                stamp = now
                log("games changed, refreshing menu entries")
                subprocess.call(["python3", LAUNCHER, "--sync-menu"],
                                stdout=open(LOG, "a"), stderr=subprocess.STDOUT)
        name = read(CORENAME)
        if name == last:
            continue
        last = name
        if not name.startswith("dcq_"):
            continue
        try:
            with open(QUICK_MAP) as f:
                game = json.load(f).get(name)
        except (OSError, ValueError):
            game = None
        if not game:
            log("unknown quick launch id %s" % name)
            continue
        log("launch %s -> %s" % (name, game))
        with open(LOG, "a") as out:
            subprocess.call(["python3", LAUNCHER, "--launch", game],
                            stdout=out, stderr=subprocess.STDOUT,
                            cwd="/media/fat/minicast")
        log("back to MiSTer")
        last = read(CORENAME)


if __name__ == "__main__":
    main()
