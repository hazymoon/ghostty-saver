#!/usr/bin/env bash
# @file record-demo.sh
# @brief Render the shaders to an animated GIF for the README
# @description
#   Every clip comes out of the screensaver's own binary, through Metal, by way
#   of `--dump` with `--frames`. Rendering the shaders a second time somewhere
#   else - in a browser, in a GL preview - would produce a picture of something
#   that is not quite what ships, and the whole point of the animation is to
#   show what ships.
#
#   Each shader gets its own palette. The clips share nothing: a matrix
#   green, a sunset, an aurora. One 128 colour table across the lot bands every
#   gradient in the set, and a GIF is allowed a palette per frame, so there is
#   no reason to make them share one.
#
#   The start times are chosen, not arbitrary. Most shaders look the same at
#   any moment, but hyperspace spends most of its cycle drifting and only jumps
#   at the end of it, and the crawl takes a couple of minutes to come round, so
#   both are wound forward to the part worth showing.
#
#   The result is not committed. It is a couple of megabytes that would change
#   every time a shader is touched, so it is uploaded to a release or an issue
#   and the README points at the URL.
#
# @section Dependencies
#   brew install ffmpeg gifsicle
#
# @section Usage
#   Scripts/record-demo.sh [--out PATH] [--width N] [--fps N] [--seconds N]
#
# @arg --out PATH    where to write the GIF (default demo.gif in the repo root)
# @arg --width N     frame width in pixels (default 440)
# @arg --fps N       frames per second (default 10)
# @arg --seconds N   seconds per shader (default 2)
# @arg --colors N    palette size per clip (default 128)
# @arg --lossy N     gifsicle lossy level, 0 to turn it off (default 30)
# @arg --keep        leave the PNG frames behind for inspection
#
# @exitcode 0 wrote the GIF
# @exitcode 1 something was missing, or a render failed

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$repo_root/.build/release/ghostty-saver"

out="$repo_root/demo.gif"
width=440
fps=10
seconds=2
colors=128
lossy=30
keep=0

# One line per clip: shader, and the iTime to start at.
clips=(
    "matrix 7.0"
    "starwars 126.0"
    "hyperspace 19.5"
    "mystify 11.0"
    "tunnel 32.0"
    "synthwave 25.0"
    "aurora 62.0"
)

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        --width) width="$2"; shift 2 ;;
        --fps) fps="$2"; shift 2 ;;
        --seconds) seconds="$2"; shift 2 ;;
        --colors) colors="$2"; shift 2 ;;
        --lossy) lossy="$2"; shift 2 ;;
        --keep) keep=1; shift ;;
        -h | --help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

for tool in ffmpeg gifsicle; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "$tool not found. Run: brew install ffmpeg gifsicle" >&2
        exit 1
    fi
done

if [ ! -x "$binary" ]; then
    echo "no binary at $binary. Run: swift build -c release" >&2
    exit 1
fi

# 16:9, and even, because some encoders will not take an odd dimension.
height=$(( width * 9 / 16 ))
height=$(( height - height % 2 ))
width=$(( width - width % 2 ))
frames=$(( seconds * fps ))

work="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-saver-demo.XXXXXXXX")"
if [ "$keep" -eq 1 ]; then
    echo "frames: $work"
else
    trap 'rm -r -- "$work" 2> /dev/null || true' EXIT
fi

# @description Find a monospaced font for the shader name in the corner.
#   Labelling is a nicety, so a machine without one still gets its GIF.
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
    echo "no font found for the labels; the clips will go out unlabelled." >&2
    echo "set GHOSTTY_SAVER_DEMO_FONT to one to get them back." >&2
fi

parts=()

for clip in "${clips[@]}"; do
    read -r shader start <<< "$clip"
    echo "rendering: $shader from iTime $start"

    "$binary" \
        --shader "$shader" \
        --size "${width}x${height}" \
        --dump "$work/$shader" \
        --at "$start" \
        --frames "$frames" \
        --fps "$fps" \
        > /dev/null

    # Name in the corner, so a reader can tell which shader they are looking at
    # and ask for it by name. Drawn top left: the crawl and the aurora's ridge
    # both live along the bottom.
    label=
    if [ -n "$font" ]; then
        size=$(( width / 34 ))
        [ "$size" -lt 10 ] && size=10
        label=",drawtext=fontfile=${font}:text=${shader}:x=${size}/2:y=${size}/2"
        label="${label}:fontsize=${size}:fontcolor=0xEBEBEB:borderw=1:bordercolor=black"
    fi

    part="$work/$shader.gif"
    # palettegen over the whole clip rather than the first frame, or a shader
    # that starts dark takes its colours from the dark.
    ffmpeg -y -loglevel error -framerate "$fps" -i "$work/$shader/%05d.png" \
        -vf "palettegen=max_colors=${colors}:stats_mode=diff" "$work/$shader.png"
    ffmpeg -y -loglevel error -framerate "$fps" -i "$work/$shader/%05d.png" \
        -i "$work/$shader.png" \
        -lavfi "[0:v]null${label}[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
        -loop 0 "$part"

    if [ "$lossy" -gt 0 ]; then
        gifsicle -O3 "--lossy=$lossy" -b "$part"
    else
        gifsicle -O3 -b "$part"
    fi
    parts+=("$part")
done

gifsicle -O3 --loopcount=0 "${parts[@]}" -o "$out"

size_kib=$(( $(wc -c < "$out") / 1024 ))
echo "wrote $out (${width}x${height}, ${fps} fps, $(( ${#clips[@]} * frames )) frames, ${size_kib} KiB)"
