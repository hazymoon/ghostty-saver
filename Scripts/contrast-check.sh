#!/usr/bin/env bash
# @file contrast-check.sh
# @brief Measure how much contrast a shader leaves for terminal text, across its cycle
# @description
#   Answers "can you still read the terminal through this?" with a number
#   instead of an opinion. The shader is rendered at a set of times through
#   the same `--dump --at` path contact-sheet.sh uses, and each frame is
#   handed to analyze-contrast.py, which computes the WCAG contrast ratio of a
#   foreground colour against every pixel and reports the worst ratio and the
#   fraction of the frame below a threshold.
#
#   Sampling across the cycle is the point: hyperspace whites out near the
#   end of its 22 seconds, and that is exactly the frame that fails.
#
#   The screensaver leaves iForegroundColor zero - there is no terminal to
#   report one - so the foreground has to be told. The default is white, the
#   commonest dark-theme text; pass --foreground more than once to measure
#   several.
#
#   A shader that fails is not necessarily wrong. Nothing is being read over
#   a screensaver, so for the catalogue this is a reported number. --gate
#   turns it into a verdict, for a shader meant to run as a custom-shader
#   under live text.
#
# @section Dependencies
#   brew install ffmpeg
#
# @section Usage
#   Scripts/contrast-check.sh --shader NAME [--times "0 5 12 30"] [--size WxH]
#                             [--foreground RRGGBB]... [--threshold N]
#                             [--gate [--allow FRACTION]]
#
# @arg --shader NAME       which shader to render (required)
# @arg --times LIST        space-separated iTime values (default: as contact-sheet.sh)
# @arg --size WxH          render size (default 480x270; the ratio is per pixel,
#                          so a small frame measures the same picture cheaply)
# @arg --foreground RRGGBB text colour to measure against (default ffffff; repeatable)
# @arg --threshold N       contrast ratio that counts as readable (default 4.5)
# @arg --gate              exit 1 if any frame has more than --allow of its
#                          pixels below the threshold
# @arg --allow FRACTION    with --gate, the fraction a frame may fail (default 0.10)
#
# @exitcode 0 measured (and, with --gate, every frame passed)
# @exitcode 1 something was missing, a render failed, or the gate tripped

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$repo_root/.build/release/ghostty-saver"
analyzer="$repo_root/Scripts/analyze-contrast.py"

shader=""
times=""
size="480x270"
foregrounds=()
threshold=4.5
gate=0
allow=0.10

while [ $# -gt 0 ]; do
    case "$1" in
        --shader) shader="$2"; shift 2 ;;
        --times) times="$2"; shift 2 ;;
        --size) size="$2"; shift 2 ;;
        --foreground) foregrounds+=("$2"); shift 2 ;;
        --threshold) threshold="$2"; shift 2 ;;
        --gate) gate=1; shift ;;
        --allow) allow="$2"; shift 2 ;;
        -h | --help) sed -n '2,44p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$shader" ]; then
    echo "--shader is required." >&2
    exit 1
fi
if ! command -v ffmpeg > /dev/null 2>&1; then
    echo "ffmpeg not found. Run: brew install ffmpeg" >&2
    exit 1
fi
if [ ! -x "$binary" ]; then
    echo "no binary at $binary. Run: swift build -c release" >&2
    exit 1
fi
if [ -n "$(find "$repo_root/core" "$repo_root/saver" "$repo_root/Generated" -name '*.swift' -newer "$binary" -print -quit)" ]; then
    echo "$binary is older than the sources. Run: swift build -c release" >&2
    exit 1
fi
if ! [[ "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "--size expects WxH: $size" >&2
    exit 1
fi
[ "${#foregrounds[@]}" -eq 0 ] && foregrounds=(ffffff)
for colour in "${foregrounds[@]}"; do
    if ! [[ "$colour" =~ ^#?[0-9A-Fa-f]{6}$ ]]; then
        echo "--foreground expects RRGGBB: $colour" >&2
        exit 1
    fi
done

# The same per-shader times contact-sheet.sh uses, so the two agree on what
# a cycle is.
if [ -z "$times" ]; then
    # shellcheck disable=SC1090
    times="$(bash -c 'source <(sed -n "/^default_times()/,/^}/p" "$1"); default_times "$2"' _ "$repo_root/Scripts/contact-sheet.sh" "$shader")"
fi
read -r -a time_list <<< "$times"

work="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-saver-contrast.XXXXXXXX")"
trap 'rm -r -- "$work" 2> /dev/null || true' EXIT

echo "shader: $shader at $size, threshold ${threshold}:1"
printf 'iTime\tforeground\tworst ratio\tbelow threshold\n'

failed_frames=0
worst_overall=""
for at in "${time_list[@]}"; do
    if ! "$binary" --shader "$shader" --size "$size" --dump "$work/frame.png" --at "$at" \
        > /dev/null 2> "$work/render.log"; then
        cat "$work/render.log" >&2
        exit 1
    fi
    # Raw RGB24 out of the PNG, so the analyzer needs no image library.
    ffmpeg -y -loglevel error -i "$work/frame.png" -f rawvideo -pix_fmt rgb24 "$work/frame.rgb"
    # Into a file rather than a process substitution: `set -e` cannot see the
    # exit status of `< <(...)`, so an analyzer that died would leave the loop
    # empty and the gate would pass on zero failures.
    if ! python3 "$analyzer" "$threshold" "${foregrounds[@]}" < "$work/frame.rgb" > "$work/analysis.tsv"; then
        exit 1
    fi
    while IFS=$'\t' read -r colour worst fraction; do
        printf '%s\t%s\t%s\t%s\n' "$at" "$colour" "$worst" "$fraction"
        if [ -z "$worst_overall" ] || [ "$(echo "$worst < $worst_overall" | bc -l)" -eq 1 ]; then
            worst_overall="$worst"
        fi
        if [ "$(echo "$fraction > $allow" | bc -l)" -eq 1 ]; then
            failed_frames=$(( failed_frames + 1 ))
        fi
    done < "$work/analysis.tsv"
done

echo
echo "worst ratio anywhere: ${worst_overall}:1"
echo "frames with more than ${allow} of the screen below ${threshold}:1: $failed_frames of $(( ${#time_list[@]} * ${#foregrounds[@]} ))"

if [ "$gate" -eq 1 ] && [ "$failed_frames" -gt 0 ]; then
    echo "FAIL: text would be unreadable over part of this cycle." >&2
    exit 1
fi
