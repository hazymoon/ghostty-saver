#!/usr/bin/env bash
# @file contact-sheet.sh
# @brief Render one shader at several iTime values and tile them into one image
# @description
#   A single frame says very little about a shader on a long cycle: hyperspace
#   only jumps near the end of its 22 seconds and the crawl takes minutes to
#   come round. This renders a named shader at a list of times through the
#   binary's own `--dump --at` path - no terminal, no tty, the same Metal
#   pipeline the screensaver runs on - labels each frame with its iTime, and
#   tiles the lot into one PNG to look at side by side.
#
#   Each shader has its own default times, since a useful sample of hyperspace
#   is not a useful sample of matrix. Pass --times to override them.
#
#   The sheet is not committed. It is a working image, so by default it goes
#   under .build/ with the rest of the build output.
#
# @section Dependencies
#   brew install ffmpeg
#
# @section Usage
#   Scripts/contact-sheet.sh --shader NAME [--times "0 5 12 30"] [--size WxH]
#                            [--columns N] [--out FILE] [--keep]
#
# @arg --shader NAME   which shader to render (required)
# @arg --times LIST    space-separated iTime values (default: per shader)
# @arg --size WxH      size of each cell in pixels (default 480x270)
# @arg --columns N     cells per row (default 4)
# @arg --out FILE      where to write the sheet (default .build/contact/NAME.png)
# @arg --keep          leave the individual frames next to the sheet
#
# @exitcode 0 wrote the sheet
# @exitcode 1 something was missing, or a render failed

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$repo_root/.build/release/ghostty-saver"

shader=""
times=""
size="480x270"
columns=4
out=""
keep=0

# @description The times worth looking at for a shader that has a shape to
#   its cycle. Anything not listed here is sampled evenly over a minute.
# @arg $1 string shader name
default_times() {
    case "$1" in
        hyperspace) echo "0 8 16 19.5 21 22 23 30" ;;
        starwars) echo "0 20 60 100 126 140 180 240" ;;
        matrix) echo "0 2 5 7.5 12 20 40 60" ;;
        toasters) echo "0 3 5 8 12 20 30 45" ;;
        aurora) echo "0 10 20 30 45 62 75 90" ;;
        mystify) echo "0 3 6 9 11 15 20 30" ;;
        *) echo "0 2 5 10 15 20 30 60" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --shader) shader="$2"; shift 2 ;;
        --times) times="$2"; shift 2 ;;
        --size) size="$2"; shift 2 ;;
        --columns) columns="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --keep) keep=1; shift ;;
        -h | --help) sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$shader" ]; then
    echo "--shader is required. Available: $("$binary" --list-shaders 2> /dev/null | awk '{print $1}' | tr '\n' ' ')" >&2
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
# A sheet of a stale binary is a picture of the wrong shader.
if [ -n "$(find "$repo_root/core" "$repo_root/saver" "$repo_root/Generated" -name '*.swift' -newer "$binary" -print -quit)" ]; then
    echo "$binary is older than the sources. Run: swift build -c release" >&2
    exit 1
fi

if ! [[ "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "--size expects WxH: $size" >&2
    exit 1
fi
if ! [[ "$columns" =~ ^[1-9][0-9]*$ ]]; then
    echo "--columns expects a positive number: $columns" >&2
    exit 1
fi

[ -z "$times" ] && times="$(default_times "$shader")"
[ -z "$out" ] && out="$repo_root/.build/contact/$shader.png"
mkdir -p "$(dirname "$out")"

read -r -a time_list <<< "$times"
count=${#time_list[@]}
if [ "$count" -eq 0 ]; then
    echo "--times is empty." >&2
    exit 1
fi
rows=$(( (count + columns - 1) / columns ))

work="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-saver-contact.XXXXXXXX")"
trap 'rm -r -- "$work" 2> /dev/null || true' EXIT

# @description Find a monospaced font for the iTime label in the corner.
#   Labelling is a nicety, so a machine without one still gets its sheet.
resolve_font() {
    local candidate
    for candidate in \
        "${GHOSTTY_SAVER_DEMO_FONT:-}" \
        /System/Library/Fonts/Menlo.ttc \
        /System/Library/Fonts/SFNSMono.ttf \
        /Library/Fonts/Arial.ttf \
        /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return
        fi
    done
}

font="$(resolve_font)"
if [ -z "$font" ]; then
    echo "no font found for the labels; the cells will go out unlabelled." >&2
    echo "set GHOSTTY_SAVER_DEMO_FONT to one to get them back." >&2
fi

width="${size%x*}"
label_size=$(( width / 24 ))
[ "$label_size" -lt 10 ] && label_size=10

index=0
for at in "${time_list[@]}"; do
    name="$(printf '%03d' "$index")"
    echo "rendering: $shader at iTime $at"
    # The binary narrates every render on stderr; keep that for a failure.
    if ! "$binary" --shader "$shader" --size "$size" --dump "$work/raw-$name.png" --at "$at" \
        > /dev/null 2> "$work/render.log"; then
        cat "$work/render.log" >&2
        exit 1
    fi

    # Label top left, the way record-demo.sh does: the crawl and the aurora's
    # ridge both live along the bottom.
    if [ -n "$font" ]; then
        ffmpeg -y -loglevel error -i "$work/raw-$name.png" \
            -vf "drawtext=fontfile=${font}:text='t=${at}':x=${label_size}/2:y=${label_size}/2:fontsize=${label_size}:fontcolor=0xEBEBEB:borderw=1:bordercolor=black" \
            "$work/cell-$name.png"
    else
        cp "$work/raw-$name.png" "$work/cell-$name.png"
    fi
    index=$(( index + 1 ))
done

# The tile filter pads an incomplete last row with the background colour, so a
# count that does not fill the grid still comes out as one image.
ffmpeg -y -loglevel error -framerate 1 -i "$work/cell-%03d.png" \
    -vf "tile=${columns}x${rows}:padding=4:margin=4:color=0x202020" \
    -frames:v 1 "$out"

if [ "$keep" -eq 1 ]; then
    keep_dir="${out%.png}-frames"
    mkdir -p "$keep_dir"
    cp "$work"/raw-*.png "$keep_dir/"
    echo "frames: $keep_dir"
fi

echo "wrote $out ($count cells of $size, $columns per row)"
