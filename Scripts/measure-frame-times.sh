#!/usr/bin/env bash
# @file measure-frame-times.sh
# @brief Measure every shader's frame cost and print the table docs/frame-times.md carries
# @description
#   The figures in docs/frame-times.md were once taken with the window
#   occluded, and none of them were right: macOS throttles drawing for a
#   window nobody can see, Ghostty's renderer stops with it, and the terminal
#   takes two to three times as long to acknowledge each frame. A shader
#   reported as missing 60fps held it once the window was visible.
#
#   So the conditions are the measurement, and this script holds them rather
#   than a person remembering to. It runs every shader in the catalog, one
#   after the other, in the terminal it is started from, and refuses the
#   conditions it can detect being wrong: a tmux pane (the doc's own
#   protocol says a Ghostty window), a window that is not frontmost, a
#   resolution that moved between runs, a run cut short by a keypress, and
#   an acknowledgement tail that looks like an occluded window.
#
#   The output is the markdown table in the doc's format plus the conditions
#   block that goes above it, so a re-measurement is a paste.
#
#   THIS TAKES OVER THE TERMINAL for --seconds times the number of shaders.
#   Leave the window on top and untouched for the whole run: a keypress ends
#   the current shader early, and the run is flagged rather than repeated.
#
# @section Usage
#   Scripts/measure-frame-times.sh [--seconds N] [--expect-size WxH] [--out DIR]
#
# @arg --seconds N        seconds per shader (default 20; the issue used 300)
# @arg --expect-size WxH  fail a run whose resolution differs from this
# @arg --out DIR          keep each run's --stats output here (default a temp dir)
#
# @exitcode 0 every run passed its checks
# @exitcode 1 could not start, or a run failed
# @exitcode 2 every run completed but at least one check was flagged

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$repo_root/.build/release/ghostty-saver"
probe_source="$repo_root/Scripts/window-probe.swift"
probe="$repo_root/.build/tools/window-probe"

seconds=20
expect_size=
out=

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) seconds="$2"; shift 2 ;;
        --expect-size) expect_size="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        -h | --help) sed -n '2,35p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ ! -x "$binary" ]; then
    echo "$binary is missing; run: swift build -c release" >&2
    exit 1
fi
if [ -n "${TMUX:-}" ]; then
    echo "this is a tmux pane. Measure in a plain Ghostty window: a pane adds tmux's" >&2
    echo "own pass over every frame, and the doc's figures are for the window." >&2
    exit 1
fi
# Standard output may be a file - the report is meant to be kept - so it is
# the tty itself that has to exist. The screensaver opens it by name when
# standard output is not one.
if ! { true < /dev/tty; } 2> /dev/null; then
    echo "there is no controlling terminal to draw on." >&2
    exit 1
fi

if [ -z "$out" ]; then
    out="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-saver-frame-times.XXXXXXXX")"
fi
mkdir -p "$out"

# Whether the window is on top is checked from outside, through the window
# server, when the probe can be built. Without it the check is skipped and
# said to be.
frontmost_check=skipped
if command -v swiftc > /dev/null 2>&1; then
    if [ ! -x "$probe" ] || [ "$probe_source" -nt "$probe" ]; then
        mkdir -p "$(dirname "$probe")"
        swiftc -O -o "$probe" "$probe_source" 2> /dev/null || true
    fi
fi
terminal_pid="$(pgrep -n -x ghostty || true)"
if [ -x "$probe" ] && [ -n "$terminal_pid" ]; then
    if "$probe" frontmost "$terminal_pid"; then
        frontmost_check=yes
    else
        echo "Ghostty is not the frontmost window. Bring it to the front and keep it" >&2
        echo "there for the run: Ghostty stops drawing a window it takes to be hidden." >&2
        exit 1
    fi
fi

shaders="$("$binary" --list-shaders | awk '{print $1}')"
count="$(wc -l <<< "$shaders" | tr -d ' ')"
total=$((seconds * count))
printf 'Measuring %s shaders for %s s each (%s s in all). Leave this window on top and untouched.\n' \
    "$count" "$seconds" "$total"
sleep 3

flagged=0
resolutions=""
rows=""

# The acknowledgement is what moves first when the window is occluded: 5 ms
# at the most with the window visible against 65 ms occluded, in the runs
# that found this. Anything past 20 is worth a second look.
ack_max_limit=20

for shader in $shaders; do
    log="$out/$shader.txt"
    if ! "$binary" --stats --seconds "$seconds" --shader "$shader" 2> "$log"; then
        echo "$shader: the screensaver failed; see $log" >&2
        exit 1
    fi

    frames="$(sed -n 's/^frames *: *\([0-9]*\).*/\1/p' "$log")"
    elapsed="$(sed -n 's/^elapsed *: *\([0-9.]*\).*/\1/p' "$log")"
    fps="$(sed -n 's/^effective fps *: *\([0-9.]*\).*/\1/p' "$log")"
    resolution="$(sed -n 's/^resolution *: *\([0-9]* x [0-9]*\) px.*/\1/p' "$log")"
    render="$(sed -n 's/^ *GPU render *: *//p' "$log")"
    ack="$(sed -n 's/^ *terminal ack *: *//p' "$log")"
    if [ -z "$frames" ] || [ -z "$render" ] || [ -z "$ack" ]; then
        echo "$shader: could not read the report; see $log" >&2
        exit 1
    fi

    # "mean 2.513  p50 2.422  p95 3.391  max 5.545" -> the four numbers.
    read -r r_mean r_p50 r_p95 r_max <<< "$(awk '{print $2, $4, $6, $8}' <<< "$render")"
    read -r a_mean _ _ a_max <<< "$(awk '{print $2, $4, $6, $8}' <<< "$ack")"

    notes=""
    # A keypress ends a run early and the report still looks complete.
    if awk -v e="$elapsed" -v s="$seconds" 'BEGIN { exit !(e < s * 0.98) }'; then
        notes="$notes cut short at ${elapsed}s;"
    fi
    if [ -n "$expect_size" ] && [ "$(tr -d ' ' <<< "$resolution")" != "$(tr 'X' 'x' <<< "$expect_size")" ]; then
        notes="$notes resolution $resolution is not $expect_size;"
    fi
    if awk -v a="$a_max" -v l="$ack_max_limit" 'BEGIN { exit !(a > l) }'; then
        notes="$notes ack max ${a_max}ms looks occluded;"
    fi
    if [ -n "$notes" ]; then flagged=1; fi
    resolutions="$resolutions$resolution"$'\n'

    rows="$rows| $shader | $r_mean | $r_p50 | $r_p95 | $r_max | $a_mean | $fps |"
    if [ -n "$notes" ]; then rows="$rows FLAGGED:$notes"; fi
    rows="$rows"$'\n'
done

distinct="$(sort -u <<< "$resolutions" | sed '/^$/d')"
if [ "$(wc -l <<< "$distinct" | tr -d ' ')" -ne 1 ]; then
    echo "the resolution changed between runs:" >&2
    echo "$distinct" >&2
    flagged=1
fi

per_frame="$(sed -n 's/^per frame *: *//p' "$out/$(head -1 <<< "$shaders").txt")"

echo
echo "## Setup"
echo
echo "- $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)"
echo "- Ghostty $(ghostty +version 2> /dev/null | sed -n 's/^Ghostty //p' | head -1): $(head -1 <<< "$distinct") px, $per_frame"
echo "- Window visible on its own display and frontmost for the whole run (checked from the window server: $frontmost_check)"
echo "- One reply per frame (\`q=0\`), 60fps target"
echo "- \`ghostty-saver --stats --seconds $seconds --shader <name>\`, run in a Ghostty window rather than a tmux pane"
echo "- $(date +%Y-%m-%d)"
echo
echo "## Results"
echo
echo "GPU render, in ms:"
echo
echo "| shader | mean | p50 | p95 | max | terminal ack (mean) | effective fps |"
echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
printf '%s' "$rows"
echo
echo "logs: $out"

if [ "$flagged" -eq 1 ]; then
    echo "at least one run was flagged; do not paste those rows." >&2
    exit 2
fi
