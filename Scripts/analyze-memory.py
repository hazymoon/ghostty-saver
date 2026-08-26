"""Decide whether a resident-set sample series is flat or climbing.

Reads the TSV that check-memory.sh writes: one row per sample, with the elapsed
seconds, Ghostty's RSS in KB, and ghostty-saver's RSS in KB.

What this can and cannot see is worth being explicit about. It catches gross
growth - images piling up, shared memory never reclaimed, anything that carries
real weight per frame. It cannot resolve a few hundred bytes per frame: against
a terminal's own allocation churn that is below the noise floor of any run
short enough to sit through.

Rather than leaving that to a fixed threshold, the slope is reported with its
own standard error, and a series is only called climbing when the slope clears
both the threshold and three times that error. The printed resolution says how
small a leak the run could have detected, so a PASS can be read for what it is.

Run with --self-test to check the verdicts against synthetic series.
"""

import math
import random
import sys

# Sustained growth above this is not churn.
SLOPE_LIMIT_MB_PER_MINUTE = 1.0
# Total growth across the measured window, over and above the slope check.
TOTAL_LIMIT_MB = 24.0
# How many standard errors the slope must clear before it counts as real.
SIGNIFICANCE = 3.0
# Samples to drop from the front, while the first frames allocate.
DEFAULT_WARMUP_SECONDS = 20.0


def read_samples(path):
    samples = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            try:
                seconds = float(parts[0])
                terminal_kb = float(parts[1])
            except ValueError:
                continue
            saver_kb = None
            if len(parts) > 2:
                try:
                    saver_kb = float(parts[2])
                except ValueError:
                    saver_kb = None
            samples.append((seconds, terminal_kb, saver_kb))
    return samples


def linear_fit(points):
    """Returns (slope, standard error of slope) in units per second."""
    n = len(points)
    if n < 3:
        return None, None

    mean_x = sum(x for x, _ in points) / n
    mean_y = sum(y for _, y in points) / n
    sxx = sum((x - mean_x) ** 2 for x, _ in points)
    if sxx == 0:
        return None, None

    slope = sum((x - mean_x) * (y - mean_y) for x, y in points) / sxx
    intercept = mean_y - slope * mean_x

    residual_sum = sum((y - (intercept + slope * x)) ** 2 for x, y in points)
    # Two degrees of freedom go to the fit itself.
    variance = residual_sum / (n - 2) if n > 2 else 0.0
    standard_error = math.sqrt(variance / sxx) if sxx > 0 else 0.0
    return slope, standard_error


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def judge(points):
    """Returns a dict describing one process's series, including a verdict."""
    if len(points) < 4:
        return {"ok": False, "reason": f"only {len(points)} samples, not enough to judge"}

    slope_per_second, error_per_second = linear_fit(points)
    slope = (slope_per_second or 0.0) * 60 / 1024
    error = (error_per_second or 0.0) * 60 / 1024

    quarter = max(1, len(points) // 4)
    first = median([y for _, y in points[:quarter]])
    last = median([y for _, y in points[-quarter:]])
    growth = (last - first) / 1024

    # A slope is only real if it clears both the threshold and the noise in
    # this particular run.
    slope_is_real = slope > SLOPE_LIMIT_MB_PER_MINUTE and slope > SIGNIFICANCE * error
    grew_too_much = growth > TOTAL_LIMIT_MB

    return {
        "ok": not (slope_is_real or grew_too_much),
        "reason": None,
        "start_mb": first / 1024,
        "end_mb": last / 1024,
        "growth_mb": growth,
        "slope_mb_per_minute": slope,
        "error_mb_per_minute": error,
        "resolution_mb_per_minute": max(SLOPE_LIMIT_MB_PER_MINUTE, SIGNIFICANCE * error),
        "window_minutes": (points[-1][0] - points[0][0]) / 60,
        "sample_count": len(points),
    }


def render(label, result):
    if result.get("reason"):
        return f"{label}: {result['reason']}"
    return (
        f"{label}\n"
        f"  window     : {result['window_minutes']:.1f} min, {result['sample_count']} samples\n"
        f"  start      : {result['start_mb']:.1f} MiB (median of first quarter)\n"
        f"  end        : {result['end_mb']:.1f} MiB (median of last quarter)\n"
        f"  growth     : {result['growth_mb']:+.1f} MiB (limit {TOTAL_LIMIT_MB:.0f})\n"
        f"  slope      : {result['slope_mb_per_minute']:+.2f} "
        f"+/- {result['error_mb_per_minute']:.2f} MiB/min\n"
        f"  resolution : this run could detect a leak above "
        f"{result['resolution_mb_per_minute']:.2f} MiB/min\n"
        f"  verdict    : {'flat' if result['ok'] else 'CLIMBING'}"
    )


def synthetic(slope_mb_per_minute, noise_kb, seed, duration=180, interval=5):
    random.seed(seed)
    points = []
    for i in range(duration // interval + 1):
        t = i * interval
        value = 306000 + t / 60 * slope_mb_per_minute * 1024
        points.append((float(t), value + random.uniform(-noise_kb, noise_kb)))
    return points


def self_test() -> None:
    """Checks the verdicts against series whose answer is known."""
    failures = []

    def check(name, points, expected_ok):
        result = judge(points)
        if result["ok"] != expected_ok:
            failures.append(f"{name}: expected {'flat' if expected_ok else 'CLIMBING'}")
            print(render(name, result))

    # Noise alone must not be called a leak, at several noise levels.
    for noise in (500, 2500, 6000):
        for seed in range(12):
            check(f"flat noise={noise} seed={seed}", synthetic(0, noise, seed), True)

    # A leak large enough to matter must be caught.
    for slope in (3.0, 8.0, 20.0):
        for seed in range(6):
            check(f"leak {slope} MiB/min seed={seed}", synthetic(slope, 2500, seed), False)

    # A step change with no ongoing slope is still growth.
    stepped = synthetic(0, 500, 1)
    stepped = [(t, y + (40 * 1024 if t > 90 else 0)) for t, y in stepped]
    check("step of 40 MiB", stepped, False)

    if failures:
        print(f"\nself-test FAILED ({len(failures)}):")
        for failure in failures:
            print(f"  {failure}")
        sys.exit(1)

    print("self-test passed: noise reads as flat, real growth reads as climbing.")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return

    if len(sys.argv) < 2:
        sys.exit("usage: analyze-memory.py <samples.tsv> [warmup seconds]\n"
                 "       analyze-memory.py --self-test")

    path = sys.argv[1]
    warmup = float(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_WARMUP_SECONDS

    samples = read_samples(path)
    if not samples:
        sys.exit(f"no samples in {path}")

    kept = [s for s in samples if s[0] >= warmup]
    if len(kept) < 4:
        print(f"note: only {len(samples)} samples, keeping the warmup period")
        kept = samples

    terminal = judge([(s[0], s[1]) for s in kept])
    print(render("Ghostty", terminal))

    saver_points = [(s[0], s[2]) for s in kept if s[2] is not None]
    saver = {"ok": True, "reason": None}
    if len(saver_points) >= 4:
        saver = judge(saver_points)
        print()
        print(render("ghostty-saver", saver))

    print()
    # Too few samples is not the same answer as growth, and reporting it as one
    # would turn "the run was too short" into "there is a leak".
    if terminal.get("reason") or saver.get("reason"):
        print("INCONCLUSIVE: not enough samples. Run for longer, or sample more often.")
        sys.exit(2)

    if terminal["ok"] and saver["ok"]:
        print("PASS: resident memory is flat across the run.")
        sys.exit(0)

    print("FAIL: resident memory climbed. Something is accumulating per frame.")
    sys.exit(1)


if __name__ == "__main__":
    main()
