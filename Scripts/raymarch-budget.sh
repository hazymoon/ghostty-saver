#!/usr/bin/env bash
# @file raymarch-budget.sh
# @brief Generate the raymarch spike variants and measure them in a Ghostty window
# @description
#   The spike behind docs/raymarch-budget.md: does a sphere-traced shader fit
#   the p95 frame budget at 4K, and how many steps does that buy? Nothing in
#   the catalogue marches, so there is no point to extrapolate from and the
#   answer has to be measured.
#
#   `gen` writes one shader per variant from docs/raymarch-budget/march.glsl.in
#   into shaders/ - a step-count series and, at one step count, each of the
#   cheapening tricks on its own - and regenerates Generated/Shaders.swift.
#   `measure` runs measure-frame-times.sh over the variants only, so the
#   conditions that document insists on (visible, frontmost, undisturbed) are
#   enforced by the same code, and prints the table for the doc.
#
#   The variants are throwaway. They live on the spike's branch and are not
#   meant to reach main.
#
# @section Usage
#   Scripts/raymarch-budget.sh gen
#   Scripts/raymarch-budget.sh measure [--seconds N] [--out DIR]
#
#   The resolution series is the binary by hand, since measure-frame-times.sh
#   measures the window it is in: see docs/raymarch-budget.md.
#
# @arg gen               write the variant shaders and regenerate
# @arg measure           run the variants through measure-frame-times.sh
# @arg --seconds N       seconds per variant (default 60)
# @arg --out DIR         keep each run's --stats output here

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/docs/raymarch-budget/march.glsl.in"

# name steps dither cap bound
variants=(
    "march-s16   16 0 0 0"
    "march-s32   32 0 0 0"
    "march-s64   64 0 0 0"
    "march-s128 128 0 0 0"
    "march-s32-dither 32 1 0 0"
    "march-s32-cap    32 0 1 0"
    "march-s32-bound  32 0 0 1"
    "march-s32-all    32 1 1 1"
)

variant_names() {
    local line
    for line in "${variants[@]}"; do
        read -r name _ <<< "$line"
        printf '%s\n' "$name"
    done
}

gen() {
    local line name steps dither cap bound
    for line in "${variants[@]}"; do
        read -r name steps dither cap bound <<< "$line"
        sed -e "s/@STEPS@/$steps/g" -e "s/@DITHER@/$dither/g" \
            -e "s/@CAP@/$cap/g" -e "s/@BOUND@/$bound/g" \
            "$template" > "$repo_root/shaders/$name.glsl"
        echo "wrote shaders/$name.glsl"
    done
    "$repo_root/Scripts/build-shaders.sh"
}

measure() {
    local seconds=60 out="" extra=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --seconds) seconds="$2"; shift 2 ;;
            --out) out="$2"; shift 2 ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
        esac
    done
    [ -n "$out" ] && extra+=(--out "$out")
    "$repo_root/Scripts/measure-frame-times.sh" --seconds "$seconds" \
        --only "$(variant_names | paste -sd, -)" ${extra[@]+"${extra[@]}"}
}

case "${1:-}" in
    gen) gen ;;
    measure) shift; measure "$@" ;;
    *) sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
