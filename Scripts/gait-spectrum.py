#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "opencv-python-headless", "matplotlib"]
# ///
"""Take the walk's motion out of a run of frames and say where in the
spectrum it is.

A gait is felt in the picture as a periodic motion: the step at the step
rate, the sway at half of it, the stride. Which of the two dominates, and by
how much, is what separates a walk from a plod, and it is not something a
still can show or a viewer can put a number on. This reads a directory of
frames from `--dump --frames --fps`, finds how much each frame moved from the
one before - translation by phase correlation, rotation by an ECC fit - and
takes the power spectrum of the three series.

What comes out, per run:

- `P_dx_stride`, `P_dy_stride`, `P_th_stride`: power in the stride band,
  0.6-1.0 Hz, of the lateral shift, the vertical shift and the roll.
- `P_dx_step`, `P_dy_step`, `P_th_step`: the same in the step band, 1.2-2.2 Hz.
- `P_sick`: power of all three, summed, in 0.1-0.4 Hz - the band the shader
  keeps empty on purpose; a variant must not raise it.
- `f_step`: where the lateral motion's peak is between 1 and 2.5 Hz, which
  is the step rate as the picture has it.
- `R_lat`: `P_dx_stride / P_dx_step`, the lateral motion once a stride over
  the lateral motion once a step. The vertical series is not in it: the eyes
  counter the bob, so the far wall stands still and the step shows only as
  parallax on the near walls, which a global shift does not see.

The picture inside the 4:3 frame is cropped away from the vignette and the
head-switch band before anything is measured, since those are fixed to the
screen and would pin the correlation at zero. A dropped frame (the deck holds
the picture, so two frames are the same) and a tracking band (the luma jumps)
are left out of the series and interpolated over.

Usage:
  Scripts/gait-spectrum.py --frames DIR --fps 20 --label NAME [--csv OUT] [--plot OUT.png]

The numbers are relative: the same windows of the lap, size and rate on both
sides of a change. Tape faults are hashed on absolute time, so every variant
sees the same ones.
"""

import argparse
import csv
import glob
import math
import os
import sys

import cv2
import numpy as np

STRIDE_BAND = (0.6, 1.0)
STEP_BAND = (1.2, 2.2)
SICK_BAND = (0.1, 0.4)
COLUMNS = ["label", "frames", "dropped", "P_dx_stride", "P_dy_stride", "P_th_stride",
           "P_dx_step", "P_dy_step", "P_th_step", "P_sick", "f_step", "R_lat"]


def picture_crop(shape: tuple[int, int]) -> tuple[slice, slice]:
    """Rows and columns of the 4:3 picture, less 8% each side for the
    vignette and the head-switch band."""
    h, w = shape
    fw = min(w, h * 4 // 3)
    fh = min(h, w * 3 // 4)
    x0 = (w - fw) // 2
    y0 = (h - fh) // 2
    mx = fw * 8 // 100
    my = fh * 8 // 100
    return slice(y0 + my, y0 + fh - my), slice(x0 + mx, x0 + fw - mx)


def load_gray(path: str) -> np.ndarray:
    """The frame as luma, blurred: the grain, the scan lines and the snow
    are fixed to the screen, and unblurred they hold the correlation at
    zero shift against the room that is moving behind them."""
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit(f"cannot read {path}")
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    sigma = max(1.0, gray.shape[0] / 135.0)   # 4 px at 540 lines
    return cv2.GaussianBlur(gray, (0, 0), sigma)


def motion_series(paths: list[str]):
    """dx, dy (pixels) and theta (radians) of each frame relative to the one
    before; NaN where the pair is a dropped frame or a tracking band."""
    prev = load_gray(paths[0])
    rows, cols = picture_crop(prev.shape)
    prev = prev[rows, cols]
    hann = cv2.createHanningWindow((prev.shape[1], prev.shape[0]), cv2.CV_32F)
    small = (prev.shape[1] // 2, prev.shape[0] // 2)
    prev_small = cv2.resize(prev, small, interpolation=cv2.INTER_AREA)
    criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 60, 1e-5)
    dx, dy, th = [], [], []
    dropped = 0
    for path in paths[1:]:
        cur = load_gray(path)[rows, cols]
        diff = float(np.mean(np.abs(cur - prev)))
        luma_jump = abs(float(cur.mean()) - float(prev.mean()))
        if diff < 1e-3 or luma_jump > 0.08:
            # The deck held the frame, or a band rolled through.
            dx.append(np.nan)
            dy.append(np.nan)
            th.append(np.nan)
            dropped += 1
        else:
            (sx, sy), _ = cv2.phaseCorrelate(prev, cur, hann)
            cur_small = cv2.resize(cur, small, interpolation=cv2.INTER_AREA)
            warp = np.array([[1.0, 0.0, sx / 2.0], [0.0, 1.0, sy / 2.0]], dtype=np.float32)
            try:
                cv2.findTransformECC(prev_small, cur_small, warp, cv2.MOTION_EUCLIDEAN, criteria, None, 5)
                angle = math.atan2(warp[1, 0], warp[0, 0])
            except cv2.error:
                angle = np.nan
            dx.append(sx)
            dy.append(sy)
            th.append(angle)
            prev_small = cur_small
        prev = cur
    return np.array(dx), np.array(dy), np.array(th), dropped


def fill(series: np.ndarray) -> np.ndarray:
    """Linear interpolation over the NaNs, so the spectrum is of a
    continuous signal."""
    idx = np.arange(len(series))
    good = ~np.isnan(series)
    if good.sum() < 2:
        return np.zeros_like(series)
    return np.interp(idx, idx[good], series[good])


def spectrum(series: np.ndarray, fps: float):
    x = fill(series)
    x = x - x.mean()
    window = np.hanning(len(x))
    spec = np.fft.rfft(x * window)
    freqs = np.fft.rfftfreq(len(x), 1.0 / fps)
    # Power per unit frequency, so a band's power does not depend on the run's length.
    power = (np.abs(spec) ** 2) / (fps * np.sum(window ** 2))
    return freqs, power


def band_power(freqs: np.ndarray, power: np.ndarray, band: tuple[float, float]) -> float:
    lo, hi = band
    mask = (freqs >= lo) & (freqs < hi)
    if not mask.any():
        return 0.0
    df = freqs[1] - freqs[0]
    return float(power[mask].sum() * df)


def analyse(frames_dir: str, fps: float, label: str, plot: str | None):
    paths = sorted(glob.glob(os.path.join(frames_dir, "*.png")))
    if len(paths) < int(fps * 4):
        raise SystemExit(f"{frames_dir}: {len(paths)} frames is too few for a spectrum")
    dx, dy, th, dropped = motion_series(paths)
    series = {"dx": dx, "dy": dy, "th": th}
    specs = {k: spectrum(v, fps) for k, v in series.items()}
    result = {"label": label, "frames": len(paths), "dropped": dropped}
    for k in ("dx", "dy", "th"):
        f, p = specs[k]
        result[f"P_{k}_stride"] = band_power(f, p, STRIDE_BAND)
        result[f"P_{k}_step"] = band_power(f, p, STEP_BAND)
    result["P_sick"] = sum(band_power(*specs[k], SICK_BAND) for k in ("dx", "dy", "th"))
    f, p = specs["dx"]
    look = (f >= 1.0) & (f < 2.5)
    result["f_step"] = float(f[look][np.argmax(p[look])]) if look.any() else 0.0
    result["R_lat"] = result["P_dx_stride"] / result["P_dx_step"] if result["P_dx_step"] > 0 else float("inf")
    if plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, axes = plt.subplots(3, 1, figsize=(8, 8), sharex=True)
        for ax, k, name in zip(axes, ("dx", "dy", "th"), ("lateral (px)", "vertical (px)", "roll (rad)")):
            f, p = specs[k]
            ax.semilogy(f, p + 1e-12)
            ax.set_ylabel(name)
            for band, colour in ((SICK_BAND, "#d33"), (STRIDE_BAND, "#39c"), (STEP_BAND, "#3a3")):
                ax.axvspan(*band, color=colour, alpha=0.12)
            ax.set_xlim(0, min(5.0, fps / 2))
        axes[-1].set_xlabel("Hz")
        fig.suptitle(f"{label}: R_lat = {result['R_lat']:.3f}")
        fig.tight_layout()
        fig.savefig(plot, dpi=100)
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--frames", required=True, help="directory of frames from --dump")
    ap.add_argument("--fps", type=float, required=True, help="the --fps the frames were dumped at")
    ap.add_argument("--label", required=True, help="name for this run in the output")
    ap.add_argument("--csv", help="append the result to this CSV (header written if new)")
    ap.add_argument("--plot", help="write the three spectra to this PNG")
    args = ap.parse_args()
    result = analyse(args.frames, args.fps, args.label, args.plot)
    line = "  ".join(f"{k}={result[k]:.4g}" if isinstance(result[k], float) else f"{k}={result[k]}" for k in COLUMNS)
    print(line)
    if args.csv:
        new = not os.path.exists(args.csv) or os.path.getsize(args.csv) == 0
        with open(args.csv, "a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=COLUMNS)
            if new:
                w.writeheader()
            w.writerow(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
