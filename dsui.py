"""DreamSTer pixel UI: a curses-like character window drawn on /dev/fb0.

Installed as /media/fat/minicast/dsui.py and imported by DreamSTer.sh, which
falls back to its plain curses UI when this module or the framebuffer is not
available (ssh pty, DREAMSTER_UI=curses, ...).

The look is the in-emulator RetroAchievements list (minicast ra/ra_osd.cpp):
dark navy page, gold title, light grey text, a thin rule under the header and
above the help line, a full-width blue bar behind the selected row and the
same 8x8 VGA glyphs, so the launcher and the in-game menus look like one UI.

Layout works like ra_osd: a "canvas" whose x unit is one source pixel of a
640-wide picture and whose y unit is one 240p line. The framebuffer is an
integer multiple of it: 640x240 is 1:1 (a 15 kHz cabinet), 640x480 repeats
every canvas line twice (the emulator's 480i look), 1280x720 is 2x2 and
1920x1080 3x3, so the text is the same size on the glass everywhere. The page
keeps ra_osd's margins (32 px, 12 lines) clear for CRT overscan unless an
overscan percentage is given.

Drawing never loops over pixels in Python (see GameSync's PHASE0_FINDINGS):
for every colour pair a 256-entry table maps a glyph row byte to its packed
pixels, a text row is a join of those per canvas line, and each line lands
in the framebuffer with one slice assignment per scanline. Rows are only
redrawn when their content changes, so moving the selection costs two rows.

Framebuffer handling (geometry read from the device, the /dev/mem fallback
for 6.x kernels whose fbdev core refuses mmap on MiSTer_fb, KD_GRAPHICS so
the text console stops drawing over us) follows GameSync's fb.py.

Font: the IBM VGA 8x8 glyphs as shipped in Linux lib/fonts/font_8x8.c
(GPL-2.0), the table minicast embeds as ra/ra_font8x8.h.
"""

import errno
import mmap
import os
import struct
import zlib

try:
    import fcntl
except ImportError:          # not Linux: only the in-memory target works
    fcntl = None

try:
    import unicodedata
except ImportError:
    unicodedata = None

# ---------------------------------------------------------------- font ---
# 128 glyphs x 8 rows, one byte per row, MSB = leftmost pixel. 0x01..0x08 are
# the CP437 symbols ra_osd uses (check, arrows, bullet, square, rule).
FONT = bytes.fromhex(
    "00000000000000000f0c0c0cec6c3c1c80e0f8fef8e08000020e3efe3e0e0200"
    "00183c7effff000000ffff7e3c1800000000183c3c18000000003c3c3c3c0000"
    "00000000ff000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000183c3c181800180066662400000000006c6cfe6cfe6c6c00"
    "183e603c067c180000c6cc183066c600386c3876dccc76001818300000000000"
    "0c18303030180c0030180c0c0c18300000663cff3c6600000018187e18180000"
    "00000000001818300000007e000000000000000000181800060c183060c08000"
    "386cc6d6c66c38001838181818187e007cc6061c3066fe007cc6063c06c67c00"
    "1c3c6cccfe0c1e00fec0c0fc06c67c003860c0fcc6c67c00fec60c1830303000"
    "7cc6c67cc6c67c007cc6c67e060c780000181800001818000018180000181830"
    "060c1830180c060000007e00007e00006030180c183060007cc60c1818001800"
    "7cc6dededec07800386cc6fec6c6c600fc66667c6666fc003c66c0c0c0663c00"
    "f86c6666666cf800fe6268786862fe00fe6268786860f0003c66c0c0ce663a00"
    "c6c6c6fec6c6c6003c18181818183c001e0c0c0ccccc7800e6666c786c66e600"
    "f06060606266fe00c6eefefed6c6c600c6e6f6decec6c6007cc6c6c6c6c67c00"
    "fc66667c6060f0007cc6c6c6c6ce7c0efc66667c6c66e6003c6630180c663c00"
    "7e7e5a1818183c00c6c6c6c6c6c67c00c6c6c6c6c66c3800c6c6c6d6d6fe6c00"
    "c6c66c386cc6c6006666663c18183c00fec68c183266fe003c30303030303c00"
    "c06030180c0602003c0c0c0c0c0c3c0010386cc60000000000000000000000ff"
    "30180c00000000000000780c7ccc7600e0607c666666dc0000007cc6c0c67c00"
    "1c0c7ccccccc760000007cc6fec07c003c6660f86060f000000076cccc7c0cf8"
    "e0606c766666e6001800381818183c00060006060666663ce060666c786ce600"
    "3818181818183c000000ecfed6d6d6000000dc666666660000007cc6c6c67c00"
    "0000dc66667c60f0000076cccc7c0c1e0000dc766060f00000007ec07c06fc00"
    "3030fc3030361c000000cccccccc76000000c6c6c66c38000000c6d6d6fe6c00"
    "0000c66c386cc6000000c6c6c67e06fc00007e4c18327e000e18187018180e00"
    "18181818181818007018180e1818700076dc0000000000000000000000000000"
)
assert len(FONT) == 128 * 8

GLYPH_CHECK, GLYPH_RIGHT, GLYPH_LEFT = 0x01, 0x02, 0x03
GLYPH_UP, GLYPH_DOWN, GLYPH_BULLET, GLYPH_SQUARE = 0x04, 0x05, 0x06, 0x07

# unicode stand-ins for the symbols (callers can write them in plain strings)
SYMBOLS = {
    u"\u221a": GLYPH_CHECK, u"\u2713": GLYPH_CHECK,
    u"\u25ba": GLYPH_RIGHT, u"\u25b6": GLYPH_RIGHT,
    u"\u25c4": GLYPH_LEFT, u"\u25c0": GLYPH_LEFT,
    u"\u25b2": GLYPH_UP, u"\u25bc": GLYPH_DOWN,
    u"\u2022": GLYPH_BULLET, u"\u25a0": GLYPH_SQUARE, u"\u2500": 0x08,
    u"\u2018": 0x27, u"\u2019": 0x27, u"\u201c": 0x22, u"\u201d": 0x22,
    u"\u2013": 0x2D, u"\u2014": 0x2D,
}


def glyph_code(ch):
    """Font index for one character: ASCII as is, known symbols, accented
    Latin letters as their plain form, anything else '?'."""
    o = ord(ch)
    if 0x20 <= o < 0x7F:
        return o
    code = SYMBOLS.get(ch)
    if code is not None:
        return code
    if unicodedata is not None:
        base = unicodedata.normalize("NFKD", ch)[:1]
        if base and 0x20 <= ord(base) < 0x7F:
            return ord(base)
    return 0x20 if o < 0x20 else 0x3F


# ------------------------------------------------------------- palette ---
# ra_osd.cpp ra_palette_rgb
BG = (16, 24, 56)
GOLD = (255, 208, 64)
TEXT = (240, 240, 240)
STRONG = (255, 255, 255)
DIM = (150, 158, 180)
HILITE = (48, 72, 150)
RED = (255, 96, 88)
BLUE = (120, 184, 255)
GREEN = (96, 224, 112)
SEP = (80, 96, 140)

CELL_W = 8
ROW_H = 10               # canvas lines per text row (8 glyph + 1 above/below)
RULE_ROW = 2             # grid row taken by the rule under the title block
RULE_ROW_H = 6
FOOT_GAP = 2             # canvas lines between the footer rule and its row

# ----------------------------------------------------------- framebuffer ---
FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602
KDSETMODE = 0x4B3A
KDGETMODE = 0x4B3B
KD_TEXT = 0x00
KD_GRAPHICS = 0x01
ACTIVE_VT_PATH = "/sys/class/tty/tty0/active"
LOWRES_MAX_HEIGHT = 288


class FramebufferError(RuntimeError):
    pass


def fb_screeninfo(fd):
    """(xres, yres, bpp, (r_off, r_len), (g..), (b..), (t_off, t_len),
    smem_start, smem_len, line_length, (xoffset, yoffset, yres_virtual))
    from the fbdev ioctls."""
    var = bytearray(160)
    fcntl.ioctl(fd, FBIOGET_VSCREENINFO, var, True)
    xres, yres, _xv, yv, xo, yo, bpp = struct.unpack_from("7I", var, 0)
    red = struct.unpack_from("2I", var, 32)
    green = struct.unpack_from("2I", var, 44)
    blue = struct.unpack_from("2I", var, 56)
    transp = struct.unpack_from("2I", var, 68)
    fix = bytearray(80)
    fcntl.ioctl(fd, FBIOGET_FSCREENINFO, fix, True)
    smem_start, smem_len = struct.unpack_from("II", fix, 16)
    stride = struct.unpack_from("I", fix, 44)[0]
    return (xres, yres, bpp, red, green, blue, transp,
            smem_start, smem_len, stride, (xo, yo, yv))


def map_framebuffer(fb_fd, length, writable=True):
    """mmap the framebuffer pixels. Linux 6.x's fbdev core refuses mmap on a
    driver without its own fb_mmap (MiSTer_fb: ENODEV); the pixels are a
    reserved region the driver still reports, so map that through /dev/mem.
    Returns (map, mem_fd or -1)."""
    prot = mmap.PROT_READ | (mmap.PROT_WRITE if writable else 0)
    try:
        return mmap.mmap(fb_fd, length, mmap.MAP_SHARED, prot), -1
    except OSError as exc:
        if exc.errno not in (errno.ENODEV, errno.EINVAL):
            raise
        smem_start = fb_screeninfo(fb_fd)[7]
        if not smem_start:
            raise
    mem_fd = os.open("/dev/mem", (os.O_RDWR if writable else os.O_RDONLY)
                     | os.O_SYNC)
    try:
        return mmap.mmap(mem_fd, length, mmap.MAP_SHARED, prot,
                         offset=smem_start), mem_fd
    except OSError as exc:
        os.close(mem_fd)
        raise FramebufferError("fb0 refuses mmap and /dev/mem at 0x%x "
                               "failed: %s" % (smem_start, exc))


class FbDisplay:
    """A pixel target (the real /dev/fb0 or an in-memory buffer for tests)
    plus the page layout for its geometry."""

    def __init__(self):
        self.width = self.height = self.stride = self.bpp = 0
        self.fmt = ((16, 8), (8, 8), (0, 8), (0, 0))
        self.buf = None           # the visible pixels (memoryview on a map)
        self._map = None
        self.pan = (0, 0)
        self.path = None
        self._fd = self._mem_fd = self._tty_fd = -1
        self._saved = None
        self.overscan = None
        self.gen = 0              # bumped when the layout is recomputed
        # bumped after every refresh that changed pixels (the post-game
        # console mirror copies on this instead of polling fb0's contents)
        self.frames = 0

    # --------------------------------------------------------- opening ---
    @classmethod
    def memory(cls, width, height, bpp=32, overscan=None):
        """In-memory framebuffer (host tests, PNG previews)."""
        d = cls()
        d.overscan = overscan
        fmt = (((11, 5), (5, 6), (0, 5), (0, 0)) if bpp == 16
               else ((16, 8), (8, 8), (0, 8), (0, 0)))
        d._set_geometry(width, height, bpp, width * (bpp // 8), fmt)
        d.buf = bytearray(d.stride * d.height)
        return d

    @classmethod
    def open_device(cls, path="/dev/fb0", overscan=None, take_console=True):
        if fcntl is None:
            raise FramebufferError("no fcntl: not Linux")
        d = cls()
        d.path = path
        d.overscan = overscan
        d._fd = os.open(path, os.O_RDWR)
        try:
            d._map_device()
            d._saved = bytes(d.buf[:d.stride * d.height])
            if take_console:
                d._graphics_mode()
        except Exception:
            d.close(restore=False)
            raise
        return d

    def _map_device(self):
        (xres, yres, bpp, red, green, blue, transp,
         _start, _len, stride, (xo, yo, _yv)) = fb_screeninfo(self._fd)
        if bpp not in (16, 24, 32):
            raise FramebufferError("unsupported %d bpp framebuffer" % bpp)
        if not xres or not yres or stride < xres * (bpp // 8):
            raise FramebufferError("bad geometry %dx%d stride %d"
                                   % (xres, yres, stride))
        # the visible window starts at (xoffset, yoffset) of the virtual
        # screen - 0,0 unless something panned it
        origin = yo * stride + xo * (bpp // 8)
        m, mem_fd = map_framebuffer(self._fd, origin + stride * yres)
        if self.buf is not None:
            self._unmap()
        self._map, self._mem_fd = m, mem_fd
        self.buf = memoryview(m)[origin:origin + stride * yres]
        self.pan = (xo, yo)
        self._set_geometry(xres, yres, bpp, stride,
                           (tuple(red), tuple(green), tuple(blue),
                            tuple(transp)))

    def _unmap(self):
        if isinstance(self.buf, memoryview):
            self.buf.release()
        self.buf = None
        m, self._map = self._map, None
        if m is not None:
            try:
                m.close()
            except (BufferError, ValueError):
                pass
        if self._mem_fd >= 0:
            os.close(self._mem_fd)
            self._mem_fd = -1

    def check_geometry(self):
        """Re-reads the device mode (MiSTer switches it at run time);
        remaps and re-lays-out when it changed. True if it did."""
        if self._fd < 0:
            return False
        info = fb_screeninfo(self._fd)
        if (info[0], info[1], info[2], info[9], info[10][:2]) == (
                self.width, self.height, self.bpp * 8, self.stride,
                self.pan):
            return False
        self._map_device()
        return True

    def _tty_candidates(self):
        out = []
        try:
            name = os.ttyname(1)
            if name.startswith("/dev/tty") and name[8:].isdigit():
                out.append(name)
        except OSError:
            pass
        try:
            with open(ACTIVE_VT_PATH) as f:
                out.append("/dev/" + f.read().strip())
        except OSError:
            pass
        return out + ["/dev/tty0", "/dev/console"]

    def _graphics_mode(self):
        """Stop the text console drawing over us (back in close())."""
        for tty in self._tty_candidates():
            try:
                fd = os.open(tty, os.O_RDWR | os.O_NOCTTY)
            except OSError:
                continue
            try:
                fcntl.ioctl(fd, KDSETMODE, KD_GRAPHICS)
            except OSError:
                os.close(fd)
                continue
            self._tty_fd = fd
            return

    def close(self, restore=True):
        if self.buf is not None and restore and self._saved is not None:
            try:
                self.buf[:len(self._saved)] = self._saved
            except (ValueError, TypeError):
                pass
        if self._fd >= 0 or self._mem_fd >= 0 or \
                self._map is not None:
            self._unmap()
        if self._tty_fd >= 0:
            try:
                fcntl.ioctl(self._tty_fd, KDSETMODE, KD_TEXT)
                # the vt redraws its (cleared) text buffer
                os.write(self._tty_fd, b"\033[2J\033[H")
            except OSError:
                pass
            os.close(self._tty_fd)
            self._tty_fd = -1
        if self._fd >= 0:
            os.close(self._fd)
            self._fd = -1

    def describe(self):
        return "fb %dx%d/%d stride %d via %s, canvas %dx%d scale %dx%d, " \
               "grid %dx%d" % (self.width, self.height, self.bpp * 8,
                               self.stride,
                               "/dev/mem" if self._mem_fd >= 0 else
                               (self.path or "memory"),
                               self.cw, self.ch, self.sx, self.sy,
                               self.cols, self.rows)

    # ---------------------------------------------------------- layout ---
    def _set_geometry(self, width, height, bpp, stride, fmt):
        self.width, self.height, self.stride = width, height, stride
        self.bpp = bpp // 8
        self.fmt = fmt
        self._tables = {}
        self._layout()
        self.gen += 1

    def _layout(self):
        w, h = self.width, self.height
        self.sx = max(1, w // 640)
        if h <= LOWRES_MAX_HEIGHT:
            self.sy = 1
        elif self.sx == 1:
            self.sy = 2
        else:
            self.sy = self.sx
        self.cw, self.ch = w // self.sx, h // self.sy
        mx = 32 if self.cw >= 640 else 12
        my = 12
        if self.overscan:
            px, py = self.overscan
            mx = max(4, int(self.cw * px / 100.0))
            my = max(2, int(self.ch * py / 100.0))
        self.mx, self.my = mx, my
        self.cols = max(8, (self.cw - 2 * mx) // CELL_W)
        top = my - 1
        foot_y = self.ch - my - ROW_H
        self.foot_rule = foot_y - FOOT_GAP
        content = top + 2 * ROW_H + RULE_ROW_H
        n = max(1, (self.foot_rule - 2 - content) // ROW_H)
        self.row_y = [top, top + ROW_H, top + 2 * ROW_H] + \
            [content + ROW_H * i for i in range(n)] + [foot_y]
        self.rows = len(self.row_y)
        self.head_rule = top + 2 * ROW_H + 1
        # horizontal spans, in canvas pixels
        self.bar_x0 = max(0, mx - 4)
        self.text_x0 = mx
        self.text_x1 = mx + self.cols * CELL_W
        self.bar_x1 = min(self.cw, self.text_x1 + 4)
        bgp, hlp = self.pack(BG), self.pack(HILITE)
        sx = self.sx
        cw = self.cw
        # row lines span the whole scanline (including the pixels right of
        # the canvas when the width is not a multiple of the scale)
        extra = self.width - cw * sx
        self._pre = {False: bgp * ((self.text_x0) * sx),
                     True: bgp * (self.bar_x0 * sx)
                     + hlp * ((self.text_x0 - self.bar_x0) * sx)}
        self._post = {False: bgp * ((cw - self.text_x1) * sx + extra),
                      True: hlp * ((self.bar_x1 - self.text_x1) * sx)
                      + bgp * ((cw - self.bar_x1) * sx + extra)}
        self._blank_cell = {False: bgp * (CELL_W * sx),
                            True: hlp * (CELL_W * sx)}
        self._blank_line = {b: self._pre[b] + self._blank_cell[b] * self.cols
                            + self._post[b] for b in (False, True)}

    # ---------------------------------------------------------- pixels ---
    def pack(self, rgb):
        (ro, rl), (go, gl), (bo, bl), (to, tl) = self.fmt
        v = (((rgb[0] >> (8 - rl)) << ro) | ((rgb[1] >> (8 - gl)) << go)
             | ((rgb[2] >> (8 - bl)) << bo))
        if tl:
            v |= ((1 << tl) - 1) << to
        return struct.pack("<I", v)[:self.bpp]

    def table(self, fg, bg):
        """256 glyph-row bytes -> packed pixels (8 * sx wide)."""
        key = (fg, bg)
        t = self._tables.get(key)
        if t is None:
            f, b = self.pack(fg) * self.sx, self.pack(bg) * self.sx
            t = [b"".join(f if v & (0x80 >> i) else b for i in range(8))
                 for v in range(256)]
            self._tables[key] = t
        return t

    def _put_line(self, cy, line, x0=0):
        """One canvas line (bytes from canvas x0) onto its sy scanlines."""
        start = cy * self.sy
        buf, stride = self.buf, self.stride
        off0 = x0 * self.sx * self.bpp
        n = len(line)
        for y in range(start, min(start + self.sy, self.height)):
            off = y * stride + off0
            buf[off:off + n] = line

    def clear_page(self):
        """Background wherever the text rows don't reach, plus the two
        rules. The caller then draws every row, so each scanline of the
        page is written once."""
        line = self.pack(BG) * (self.stride // self.bpp)
        line += b"\0" * (self.stride - len(line))
        covered = [False] * self.ch
        for r, y in enumerate(self.row_y):
            if r != RULE_ROW:
                for k in range(max(0, y), min(y + ROW_H, self.ch)):
                    covered[k] = True
        c = 0
        while c < self.ch:                # runs of uncovered canvas lines
            if covered[c]:
                c += 1
                continue
            end = c
            while end < self.ch and not covered[end]:
                end += 1
            s0, s1 = c * self.sy, min(end * self.sy, self.height)
            self.buf[s0 * self.stride:s1 * self.stride] = line * (s1 - s0)
            c = end
        s0 = self.ch * self.sy            # below the canvas
        if s0 < self.height:
            self.buf[s0 * self.stride:self.height * self.stride] = \
                line * (self.height - s0)
        rule = self.pack(SEP) * ((self.text_x1 - self.text_x0) * self.sx)
        for cy in (self.head_rule, self.foot_rule):
            if 0 <= cy < self.ch:
                self._put_line(cy, rule, self.text_x0)

    def draw_row(self, r, cells, bar):
        """cells: per column None or (code, fg, bg-or-None)."""
        y0 = self.row_y[r]
        row_bg = HILITE if bar else BG
        info = []
        blank = self._blank_cell[bar]
        for c in cells:
            if c is None:
                info.append(None)
            else:
                info.append((self.table(c[1], c[2] or row_bg), c[0] * 8))
        pre, post = self._pre[bar], self._post[bar]
        blank_line = self._blank_line[bar]
        for gy in range(ROW_H):
            g = gy - 1
            if 0 <= g < 8:
                parts = [pre]
                for i in info:
                    if i is None:
                        parts.append(blank)
                    else:
                        parts.append(i[0][FONT[i[1] + g]])
                parts.append(post)
                line = b"".join(parts)
            else:
                line = blank_line
            self._put_line(y0 + gy, line)

    # ------------------------------------------------------------ test ---
    def rgb_bytes(self):
        """The picture as packed RGB (for PNGs)."""
        w, h, bpp = self.width, self.height, self.bpp
        out = bytearray(w * h * 3)
        (ro, rl), (go, gl), (bo, bl), _ = self.fmt
        if bpp == 2:                 # test-only path: a plain loop is fine
            vals = struct.unpack_from("<%dH" % (self.stride // 2 * h), self.buf)
            sw = self.stride // 2
            rm, gm, bm = (1 << rl) - 1, (1 << gl) - 1, (1 << bl) - 1
            i = 0
            for y in range(h):
                base = y * sw
                for x in range(w):
                    v = vals[base + x]
                    out[i] = ((v >> ro) & rm) * 255 // rm
                    out[i + 1] = ((v >> go) & gm) * 255 // gm
                    out[i + 2] = ((v >> bo) & bm) * 255 // bm
                    i += 3
            return bytes(out)
        for y in range(h):
            line = bytes(self.buf[y * self.stride:y * self.stride + w * bpp])
            o = y * w * 3
            out[o:o + w * 3:3] = line[ro // 8::bpp]
            out[o + 1:o + w * 3:3] = line[go // 8::bpp]
            out[o + 2:o + w * 3:3] = line[bo // 8::bpp]
        return bytes(out)

    def to_png(self, path, double_lowres=True):
        """Writes the picture; 240-line modes are line-doubled so the PNG
        has the proportions the tube shows (like the ra_popup previews)."""
        rgb = self.rgb_bytes()
        w, h = self.width, self.height
        if double_lowres and h <= LOWRES_MAX_HEIGHT:
            rows = [rgb[y * w * 3:(y + 1) * w * 3] for y in range(h)]
            rgb = b"".join(r + r for r in rows)
            h *= 2
        write_png(path, w, h, rgb)


def write_png(path, width, height, rgb):
    """Minimal RGB8 PNG writer (stdlib only)."""
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    stride = width * 3
    raw = b"".join(b"\0" + rgb[y * stride:(y + 1) * stride]
                   for y in range(height))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# -------------------------------------------------------------- window ---

class FbWindow:
    """The subset of a curses window DreamSTer.sh draws with, rendered on an
    FbDisplay. Input (getch/timeout/nodelay/keypad) is delegated to a real
    curses window reading the tty, so keyboard, ssh and the evdev nav pump
    work exactly as with the text UI.

    attr: (pair << 8) | flags, as curses' COLOR_PAIR() encodes it. styles
    maps a pair number to (fg, bg or None); A_BOLD on pair 0 is STRONG.
    Grid row 2 is the rule under the title block (writes to it are
    dropped); bar(y) puts the selection bar behind row y."""

    is_pixel = True

    def __init__(self, display, inp=None, styles=None, bold_flag=0x200000):
        self.d = display
        self.inp = inp
        self.styles = dict(styles or {})
        self.bold_flag = bold_flag
        self._gen = None
        self._reset()

    def _reset(self):
        d = self.d
        self._gen = d.gen
        self.cells = [[None] * d.cols for _ in range(d.rows)]
        self.bars = set()
        self.shown = None          # None: repaint everything next refresh

    # ------------------------------------------------------------ curses ---
    def getmaxyx(self):
        return self.d.rows, self.d.cols

    def erase(self):
        if self._gen != self.d.gen:
            self._reset()
            return
        cols = self.d.cols
        self.cells = [[None] * cols for _ in range(self.d.rows)]
        self.bars = set()

    def clear(self):
        self.erase()
        self.shown = None

    def _style(self, attr):
        pair = (attr >> 8) & 0xFF
        st = self.styles.get(pair)
        if st is None:
            st = (TEXT, None)
        if pair == 0 and attr & self.bold_flag:
            st = (STRONG, st[1])
        return st

    def addstr(self, y, x, text, attr=0):
        if self._gen != self.d.gen:
            self._reset()
        if y < 0 or y >= self.d.rows or y == RULE_ROW or x >= self.d.cols:
            return
        fg, bg = self._style(attr)
        row = self.cells[y]
        if x < 0:
            text = text[-x:]
            x = 0
        for ch in text[:self.d.cols - x]:
            row[x] = (glyph_code(ch), fg, bg)
            x += 1

    def addnstr(self, y, x, text, n, attr=0):
        self.addstr(y, x, text[:max(0, n)], attr)

    def bar(self, y):
        if 0 <= y < self.d.rows and y != RULE_ROW:
            self.bars.add(y)

    def move(self, y, x):
        pass

    def noutrefresh(self):
        self.refresh()

    def refresh(self):
        d = self.d
        if self._gen != d.gen:
            self._reset()
        drew = False
        if self.shown is None:
            d.clear_page()
            self.shown = [None] * d.rows
            drew = True
        for r in range(d.rows):
            if r == RULE_ROW:
                continue
            row = self.cells[r]
            sig = (tuple(row), r in self.bars)
            if self.shown[r] != sig:
                d.draw_row(r, row, sig[1])
                self.shown[r] = sig
                drew = True
        if drew:
            d.frames += 1         # after the writes: a copy racing them
                                  # sees the count change again

    # ------------------------------------------------------------- input ---
    def getch(self):
        return self.inp.getch() if self.inp is not None else -1

    def timeout(self, ms):
        if self.inp is not None:
            self.inp.timeout(ms)

    def nodelay(self, flag):
        if self.inp is not None:
            self.inp.nodelay(flag)

    def keypad(self, flag):
        if self.inp is not None:
            self.inp.keypad(flag)
