#!/usr/bin/env bash
# @file gait-spectrum.sh
# @brief Measure the backrooms' walk, as it is and under each variant of its gait constants
# @description
#   The walk reads as heavy-footed (#69), and the question is which of its
#   constants that comes from. Each variant in Scripts/gait-variants/ is a
#   patch to shaders/backrooms.glsl that changes constants only. For the
#   tree as it is, and then for each variant in turn, this applies the patch,
#   regenerates and builds, dumps two stretches of ordinary walking at
#   --fps, runs Scripts/gait-spectrum.py over each, and takes the patch off
#   again. The tree is left as it was found, Generated/Shaders.swift
#   included.
#
#   The stretches are lap seconds 0-23 and 88-104: before the creep to the
#   first pause, and between the glance back and the second pause. Neither
#   has a fright, a pause, a look or a storm in it, so what moves is the
#   gait.
#
#   Nothing here commits. The results go to .build/gait/results.csv and a
#   spectrum PNG per run under .build/gait/<variant>/.
#
# @section Dependencies
#   uv (Scripts/gait-spectrum.py fetches numpy, OpenCV and matplotlib itself)
#
# @section Usage
#   Scripts/gait-spectrum.sh [--variants "A B"] [--fps N] [--size WxH]
#
# @arg --variants LIST  which of Scripts/gait-variants/*.patch to run, by
#                       stem (default: all of them, after the unpatched tree)
# @arg --fps N          frames a second to dump (default 20)
# @arg --size WxH       frame size (default 960x540)
#
# @exitcode 0 every run measured
# @exitcode 1 a build, dump or measurement failed
# @exitcode 2 the tree was not clean to begin with

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
binary="$repo_root/.build/release/ghostty-saver"
out="$repo_root/.build/gait"
variants_dir="$repo_root/Scripts/gait-variants"

variants=""
fps=20
size="960x540"

while [ $# -gt 0 ]; do
    case "$1" in
        --variants) variants="$2"; shift 2 ;;
        --fps) fps="$2"; shift 2 ;;
        --size) size="$2"; shift 2 ;;
        -h | --help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -n "$(git status --porcelain -- shaders Generated)" ]; then
    echo "shaders/ or Generated/ has uncommitted changes; commit or stash first" >&2
    exit 2
fi
if [ -z "$variants" ]; then
    variants="$(cd "$variants_dir" && ls *.patch | sed 's/\.patch$//' | tr '\n' ' ')"
fi

# One line per stretch: name, lap second it starts, seconds it lasts.
windows=(
    "w0 0 23"
    "w88 88 16"
)

mkdir -p "$out"
results="$out/results.csv"
: > "$results"

build() {
    Scripts/build-shaders.sh > /dev/null
    swift build -c release 2>&1 | grep -E 'error:' && return 1
    return 0
}

measure() {
    local name="$1"
    for w in "${windows[@]}"; do
        read -r wname at seconds <<< "$w"
        local dir="$out/$name/$wname"
        mkdir -p "$dir"
        find "$dir" -name '*.png' -delete
        "$binary" --shader backrooms --size "$size" --dump "$dir" --at "$at" \
            --frames "$((seconds * fps))" --fps "$fps" > /dev/null 2>&1
        Scripts/gait-spectrum.py --frames "$dir" --fps "$fps" --label "$name/$wname" \
            --csv "$results" --plot "$out/$name/$wname.png"
    done
}

echo "== as it is"
build
measure "main"

for v in $variants; do
    patch="$variants_dir/$v.patch"
    [ -f "$patch" ] || { echo "no such variant: $v" >&2; exit 1; }
    echo "== $v"
    git apply "$patch"
    if ! build; then
        git apply -R "$patch"
        exit 1
    fi
    measure "$v" || { git apply -R "$patch"; exit 1; }
    git apply -R "$patch"
done

# Put Generated/Shaders.swift back to the tree's own.
Scripts/build-shaders.sh > /dev/null
if [ -n "$(git status --porcelain -- shaders Generated)" ]; then
    echo "the tree did not come back clean; check git status" >&2
    exit 1
fi
echo "results: $results"
