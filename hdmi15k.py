#!/usr/bin/env python3
"""Re-point the ADV7513 at the 15 kHz raster of the DreamSTer CRT bitstream.

Run AFTER minicast's setup_hdmi (which leaves the chip in its 1080p/VIC 16
setup). Mirrors Main_MiSTer's direct_video mode registers: custom timing
(VIC 0), manual/no pixel repetition, 4:3, syncs as generated (active high).
Audio CTS is left in automatic mode by setup_hdmi (reg 0x0A[7]=0), so the
27 MHz pixel clock needs no N/CTS change.

  hdmi15k.py            apply the 15 kHz registers + DV1 SPD for 480i
  hdmi15k.py --240p     same, DV1 SPD describing the 240p bitstream
  hdmi15k.py --tv       standard HDMI for a TV instead: CEA 1440x480i (VIC 6)
                        or, with --240p, 1440x240p (VIC 8), 4:3, pixel
                        repetition by the chip, no DV1 SPD - needs a bitstream
                        with CRT_CTRL[5] (REVISION 8) set, which switches the
                        HDMI pins to separate syncs + active-picture DE
  hdmi15k.py --probe    print ADV7513 status (detected input VIC, HPD, PLL)

Direct-video DACs (e.g. MiSTercade V2) rely on Main_MiSTer's custom "DV1"
SPD InfoFrame (video.cpp spd_config_update) for interlace/pixel-repetition
metadata; setup_hdmi sends no SPD at all, so it is rebuilt here.
"""
import ctypes, fcntl, os, struct, sys

I2C_SLAVE, I2C_SMBUS = 0x0703, 0x0720
ADV_MAIN, ADV_REV = 0x39, 0x13

REGS = [
    # values read back from Main_MiSTer's working direct_video menu mode on
    # the MiSTercade (reg dump adv_menu.txt): proven with the CRT + DAC
    (0x17, 0x62),        # HS+VS polarity inverted (negative syncs on the link), aspect bit
    (0x3B, 0x00),        # automatic pixel repetition
    (0x3C, 0),           # VIC 0: custom timing (15 kHz 1440x480i / 240p)
]

def _smbus(fd, rw, reg, size, data):
    fcntl.ioctl(fd, I2C_SMBUS, struct.pack("BBxxIP", rw, reg, size, ctypes.addressof(data)))

def rd(fd, reg):
    data = ctypes.create_string_buffer(34)
    _smbus(fd, 1, reg, 2, data)          # I2C_SMBUS_READ, BYTE_DATA
    return data.raw[0]

def wr(fd, reg, val):
    data = ctypes.create_string_buffer(bytes([val]), 34)
    _smbus(fd, 0, reg, 2, data)          # I2C_SMBUS_WRITE, BYTE_DATA

def open_adv():
    """Same search as setup_hdmi's i2c_open: first of /dev/i2c-0..2 that answers."""
    for bus in range(3):
        try:
            fd = os.open("/dev/i2c-%d" % bus, os.O_RDWR)
        except OSError:
            continue
        try:
            fcntl.ioctl(fd, I2C_SLAVE, ADV_MAIN)
            if rd(fd, 0x00) == ADV_REV:
                return fd, bus
        except OSError:
            pass
        os.close(fd)
    raise SystemExit("ADV7513 not found on /dev/i2c-0..2")

def dv1_spd(interlaced):
    """Main_MiSTer DV1 SPD InfoFrame for the spg 15 kHz raster (1440 samples =
    720 px x2, 240 active lines per field/frame)."""
    de_h, de_v, width = 1440, 240, 720
    height = 480 if interlaced else 240
    data = [0x83, 0x01, 25, 0,                 # SPD header, len, checksum (ADV auto)
            ord('D'), ord('V'), ord('1'),
            1 if interlaced else 0,            # flags: [0] interlaced, [2] menu, [3] rotated
            2,                                 # pixel repetition
            de_h & 0xFF, de_h >> 8, de_v & 0xFF, de_v >> 8,
            width & 0xFF, width >> 8, height & 0xFF, height >> 8]
    name = b"DREAMCAST"
    data += list(name) + [0] * (31 - len(data) - len(name))
    return data[:31]

def write_spd(fd, bus, data):
    pm = rd(fd, 0x45) >> 1                      # packet-memory i2c address (0x38)
    wr(fd, 0x40, rd(fd, 0x40) | 0x40)           # enable SPD packet
    pfd = os.open("/dev/i2c-%d" % bus, os.O_RDWR)
    try:
        fcntl.ioctl(pfd, I2C_SLAVE, pm)
        wr(pfd, 0x1F, 0x80)                     # hold packet update
        for i, b in enumerate(data):
            wr(pfd, i, b)
        wr(pfd, 0x1F, 0x00)                     # release
    finally:
        os.close(pfd)

def probe(fd, bus):
    r = {a: rd(fd, a) for a in (0x17, 0x3B, 0x3C, 0x3D, 0x3E, 0x42, 0x9E)}
    print("ADV7513 on /dev/i2c-%d" % bus)
    print("  VIC detected from input (0x3E): %d" % (r[0x3E] >> 2))
    print("  VIC sent to sink (0x3D)       : %d" % (r[0x3D] & 0x3F))
    print("  VIC programmed (0x3C)         : %d" % (r[0x3C] & 0x3F))
    print("  pixel repetition (0x3B)       : 0x%02X" % r[0x3B])
    print("  sync/aspect (0x17)            : 0x%02X" % r[0x17])
    print("  HPD=%d monitor-sense=%d (0x42)  : 0x%02X" % ((r[0x42] >> 6) & 1, (r[0x42] >> 5) & 1, r[0x42]))
    print("  PLL locked=%d (0x9E)            : 0x%02X" % ((r[0x9E] >> 4) & 1, r[0x9E]))

def tv_mode(fd, bus, interlaced):
    """The raster as a regular CEA 480i / 240p HDMI source: the chip detects
    the VIC from the input timing and repeats pixels itself; the AVI frame
    says 4:3. setup_hdmi's other settings (RGB 444, audio) stay."""
    vic = 6 if interlaced else 8
    wr(fd, 0x17, 0x60)                   # syncs as Main's 15 kHz modes, aspect 4:3
    wr(fd, 0x3B, 0x00)                   # automatic pixel repetition
    wr(fd, 0x3C, vic)
    wr(fd, 0x56, 0x18)                   # AVI: picture 4:3, active format = picture
    wr(fd, 0x40, rd(fd, 0x40) & ~0x40)   # no SPD (the DV1 frame is for DAC adapters)
    print("ADV7513 (/dev/i2c-%d) set for HDMI TV: VIC %d (%s 4:3)"
          % (bus, vic, "480i" if interlaced else "240p"))

def main():
    fd, bus = open_adv()
    try:
        if "--probe" in sys.argv:
            probe(fd, bus)
            return 0
        if "--tv" in sys.argv:
            tv_mode(fd, bus, "--240p" not in sys.argv)
            return 0
        for reg, val in REGS:
            wr(fd, reg, val)
        interlaced = "--240p" not in sys.argv
        write_spd(fd, bus, dv1_spd(interlaced))
        print("ADV7513 (/dev/i2c-%d) set for 15 kHz (%s): menu-matched regs + DV1 SPD"
              % (bus, "480i" if interlaced else "240p"))
    finally:
        os.close(fd)
    return 0

if __name__ == "__main__":
    sys.exit(main())
