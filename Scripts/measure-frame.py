#!/usr/bin/env python3
"""Put numbers on a rendered backrooms frame, so a change to its look is a
comparison rather than an impression.

Reads PNG frames from `--dump`, decodes them through ffmpeg as raw RGB24, and
for each one reports, inside the 4:3 picture (the pillarbox bars are not part
of the picture):

- `Y`: mean luma, video weights (0.299, 0.587, 0.114), on 0-255; and the same
  for the top, middle and bottom thirds of the picture, which is roughly the
  ceiling, the walls and the floor when the walker is looking down a room.
- `wall_cv`: the coefficient of variation of the middle third's column means -
  how much the wall's brightness swings across the picture.
- `wall_hp`: the same after a running mean a sixteenth of the picture wide is
  taken out, which leaves the steps and bands and drops the slow fall-off of
  a wall receding into fog. This is the number for the lighting's cell-boundary
  steps.
- `box_x` and `box_y`: in the bottom third, the mean chroma difference across
  the boundaries of the tape's colour cells (CHROMA_SAMPLES across, half of
  LINES down) over the mean difference everywhere else. Blotches with hard
  edges push this above 1; smooth colour noise, or none, leaves it near 1.

The metrics are relative: the value of one frame says little, the same frame
before and after an edit says what the edit did. Use the same iTime, size
and shader on both sides.

Usage: Scripts/measure-frame.py [--csv] FRAME.png [FRAME.png ...]
"""

import struct
import subprocess
import sys
from array import array

CHROMA_SAMPLES = 40   # must match shaders/backrooms.glsl
CHROMA_LINES = 240    # LINES * 0.5, likewise


def png_size(path: str) -> tuple[int, int]:
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError(f"{path}: not a PNG")
    width, height = struct.unpack(">II", head[16:24])
    return width, height


def decode(path: str) -> bytes:
    result = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        stdout=subprocess.PIPE, check=True,
    )
    return result.stdout


def picture_box(width: int, height: int) -> tuple[int, int, int, int]:
    """x0, y0, w, h of the 4:3 picture inside a frame of this size."""
    fw = min(width, height * 4 // 3)
    fh = min(height, width * 3 // 4)
    return (width - fw) // 2, (height - fh) // 2, fw, fh


def luma_and_chroma(frame: bytes, width: int, box: tuple[int, int, int, int]):
    """Per-pixel Y (0-255 float) and the I chroma component, picture only."""
    x0, y0, w, h = box
    y = array("f", bytes(4 * w * h))
    i = array("f", bytes(4 * w * h))
    k = 0
    for row in range(y0, y0 + h):
        base = (row * width + x0) * 3
        for col in range(w):
            r = frame[base]
            g = frame[base + 1]
            b = frame[base + 2]
            y[k] = 0.299 * r + 0.587 * g + 0.114 * b
            i[k] = 0.596 * r - 0.274 * g - 0.322 * b
            k += 1
            base += 3
    return y, i


def mean(values) -> float:
    return sum(values) / len(values) if values else 0.0


def std(values) -> float:
    m = mean(values)
    return (sum((v - m) ** 2 for v in values) / len(values)) ** 0.5 if values else 0.0


def thirds(y, w: int, h: int) -> tuple[float, float, float]:
    third = h // 3
    return (
        mean(y[0:third * w]),
        mean(y[third * w:2 * third * w]),
        mean(y[2 * third * w:3 * third * w]),
    )


def wall_bands(y, w: int, h: int) -> tuple[float, float]:
    third = h // 3
    cols = [0.0] * w
    for row in range(third, 2 * third):
        base = row * w
        for col in range(w):
            cols[col] += y[base + col]
    n = float(third)
    cols = [c / n for c in cols]
    m = mean(cols)
    if m == 0.0:
        return 0.0, 0.0
    cv = std(cols) / m
    half = max(1, w // 32)
    hp = []
    for col in range(w):
        lo = max(0, col - half)
        hi = min(w, col + half + 1)
        hp.append(cols[col] - mean(cols[lo:hi]))
    return cv, std(hp) / m


def box_edges(i, w: int, h: int) -> tuple[float, float]:
    third = h // 3
    rows = range(2 * third, 3 * third)
    # Columns and rows on which a colour cell begins, in picture pixels.
    xb = {round(k * w / CHROMA_SAMPLES) for k in range(1, CHROMA_SAMPLES)}
    yb = {round(k * h / CHROMA_LINES) for k in range(1, CHROMA_LINES)}
    on_x = off_x = 0.0
    n_on_x = n_off_x = 0
    on_y = off_y = 0.0
    n_on_y = n_off_y = 0
    for row in rows:
        base = row * w
        for col in range(1, w):
            d = abs(i[base + col] - i[base + col - 1])
            if col in xb:
                on_x += d
                n_on_x += 1
            else:
                off_x += d
                n_off_x += 1
        if row == 0:
            continue
        above = (row - 1) * w
        d = 0.0
        for col in range(w):
            d += abs(i[base + col] - i[above + col])
        if row in yb:
            on_y += d
            n_on_y += w
        else:
            off_y += d
            n_off_y += w
    bx = (on_x / n_on_x) / (off_x / n_off_x) if n_on_x and n_off_x and off_x else 0.0
    by = (on_y / n_on_y) / (off_y / n_off_y) if n_on_y and n_off_y and off_y else 0.0
    return bx, by


def measure(path: str) -> dict:
    width, height = png_size(path)
    frame = decode(path)
    if len(frame) != width * height * 3:
        raise ValueError(f"{path}: decoded {len(frame)} bytes for {width}x{height}")
    box = picture_box(width, height)
    y, i = luma_and_chroma(frame, width, box)
    w, h = box[2], box[3]
    top, mid, bot = thirds(y, w, h)
    cv, hp = wall_bands(y, w, h)
    bx, by = box_edges(i, w, h)
    return {
        "file": path, "size": f"{width}x{height}",
        "Y": mean(y), "Y_top": top, "Y_mid": mid, "Y_bot": bot,
        "wall_cv": cv, "wall_hp": hp, "box_x": bx, "box_y": by,
    }


COLUMNS = ["file", "size", "Y", "Y_top", "Y_mid", "Y_bot", "wall_cv", "wall_hp", "box_x", "box_y"]


def fmt(key: str, value) -> str:
    if key in ("file", "size"):
        return str(value)
    if key.startswith("Y"):
        return f"{value:.1f}"
    return f"{value:.4f}"


def main(argv: list[str]) -> int:
    csv = "--csv" in argv
    paths = [a for a in argv if a != "--csv"]
    if not paths:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    rows = [measure(p) for p in paths]
    if csv:
        print(",".join(COLUMNS))
        for r in rows:
            print(",".join(fmt(k, r[k]) for k in COLUMNS))
        return 0
    widths = {k: max(len(k), *(len(fmt(k, r[k])) for r in rows)) for k in COLUMNS}
    print("  ".join(k.ljust(widths[k]) for k in COLUMNS))
    for r in rows:
        print("  ".join(fmt(k, r[k]).ljust(widths[k]) for k in COLUMNS))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
