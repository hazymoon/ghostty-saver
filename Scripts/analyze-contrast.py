"""Measure the contrast a rendered frame leaves for text drawn over it.

Reads one frame as raw RGB24 on stdin - contrast-check.sh gets it there
through ffmpeg - and, for each foreground colour asked for, computes the WCAG
contrast ratio of that colour against every pixel: (L1 + 0.05) / (L2 + 0.05)
over the relative luminance of the two, brighter on top. What comes out is
the worst ratio anywhere in the frame and the fraction of the frame below a
threshold, which is the number a "can you still read the terminal through
this?" question wants instead of an impression of one frame.

The frame's own alpha is ignored: the terminal composites the shader under
the text, so the pixel is what the text sits on.

Run with --self-test to check the arithmetic against known colours.
"""

import sys

# WCAG's threshold for normal text.
DEFAULT_THRESHOLD = 4.5


def linear(channel: int) -> float:
    """sRGB 0-255 to linear light, as WCAG defines it."""
    c = channel / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


# One entry per 8-bit value, so a frame costs three lookups per pixel.
LINEAR = [linear(v) for v in range(256)]


def luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = rgb
    return 0.2126 * LINEAR[r] + 0.7152 * LINEAR[g] + 0.0722 * LINEAR[b]


def ratio(a: float, b: float) -> float:
    """Contrast ratio between two relative luminances."""
    high, low = (a, b) if a >= b else (b, a)
    return (high + 0.05) / (low + 0.05)


def parse_colour(text: str) -> tuple[int, int, int]:
    hex_text = text.lstrip("#")
    if len(hex_text) != 6:
        raise ValueError(f"expected RRGGBB, got {text!r}")
    return tuple(int(hex_text[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def measure(frame: bytes, foreground: tuple[int, int, int], threshold: float) -> tuple[float, float]:
    """Worst ratio in the frame, and the fraction of pixels below the threshold."""
    if len(frame) % 3 != 0:
        raise ValueError(f"frame is {len(frame)} bytes, not a whole number of RGB pixels")
    fg = luminance(foreground)
    # The ratio is monotonic in the pixel's luminance on either side of the
    # foreground, so the threshold turns into a band of luminances that fail
    # and each pixel is one comparison.
    fail_high = (fg + 0.05) / threshold - 0.05      # darker than this passes
    fail_low = (fg + 0.05) * threshold - 0.05       # brighter than this passes
    pixels = len(frame) // 3
    below = 0
    worst = float("inf")
    for i in range(0, len(frame), 3):
        lum = 0.2126 * LINEAR[frame[i]] + 0.7152 * LINEAR[frame[i + 1]] + 0.0722 * LINEAR[frame[i + 2]]
        if fail_high < lum < fail_low:
            below += 1
        r = ratio(fg, lum)
        if r < worst:
            worst = r
    return worst, below / pixels


def self_test() -> None:
    failures = []

    def check(name: str, got: float, want: float, tolerance: float = 0.01) -> None:
        if abs(got - want) > tolerance:
            failures.append(f"{name}: got {got:.3f}, wanted {want:.3f}")

    black = bytes([0, 0, 0]) * 100
    white = bytes([255, 255, 255]) * 100
    grey = bytes([118, 118, 118]) * 100   # #767676 is the classic 4.54:1 grey on white

    worst, fraction = measure(black, (255, 255, 255), DEFAULT_THRESHOLD)
    check("white on black, worst", worst, 21.0)
    check("white on black, below", fraction, 0.0)

    worst, fraction = measure(white, (255, 255, 255), DEFAULT_THRESHOLD)
    check("white on white, worst", worst, 1.0)
    check("white on white, below", fraction, 1.0)

    worst, fraction = measure(grey, (255, 255, 255), DEFAULT_THRESHOLD)
    check("white on #767676, worst", worst, 4.54, 0.02)
    check("white on #767676, below", fraction, 0.0)

    worst, fraction = measure(grey, (255, 255, 255), 5.0)
    check("white on #767676 at 5:1, below", fraction, 1.0)

    half = black[:150] + white[:150]
    _, fraction = measure(half, (255, 255, 255), DEFAULT_THRESHOLD)
    check("half and half, below", fraction, 0.5)

    if failures:
        print(f"\nself-test FAILED ({len(failures)}):")
        for failure in failures:
            print(f"  {failure}")
        sys.exit(1)
    print("self-test passed: the ratio and the threshold band agree with WCAG's known pairs.")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) < 3:
        sys.exit("usage: analyze-contrast.py THRESHOLD RRGGBB [RRGGBB ...] < frame.rgb\n"
                 "       analyze-contrast.py --self-test")

    threshold = float(sys.argv[1])
    foregrounds = [parse_colour(text) for text in sys.argv[2:]]
    frame = sys.stdin.buffer.read()
    for text, foreground in zip(sys.argv[2:], foregrounds):
        worst, fraction = measure(frame, foreground, threshold)
        # One line per foreground: colour, worst ratio, fraction below.
        print(f"{text.lstrip('#')}\t{worst:.2f}\t{fraction:.4f}")


if __name__ == "__main__":
    main()
