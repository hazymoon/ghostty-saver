#!/usr/bin/env bash
# @file check-custom-shaders.sh
# @brief Compile every custom-shaders/*.glsl the way Ghostty will
# @description
#   The files under custom-shaders/ read iChannel0, the terminal's own image,
#   so they only work as a Ghostty custom-shader and never go through
#   build-shaders.sh: there is no terminal image in the screensaver to bind,
#   so they would draw black there and fail the suite.
#
#   What can be checked without a terminal is that Ghostty's own toolchain
#   accepts them. Ghostty prepends shadertoy_prefix.glsl, compiles with
#   glslang and converts with spirv-cross using --msl-decoration-binding, so
#   this does exactly that and stops at the first file that fails. It does
#   not render anything.
#
#   Runs locally only. CI installs neither glslang nor spirv-cross.
#
# @section Dependencies
#   brew install glslang spirv-cross
#
# @section Usage
#   Scripts/check-custom-shaders.sh [FILE...]
#
# @exitcode 0 every file compiled and converted
# @exitcode 1 a tool was missing or a file failed

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty_ref="${GHOSTTY_SAVER_PREFIX_REF:-v1.3.1}"
prefix_url="https://raw.githubusercontent.com/ghostty-org/ghostty/$ghostty_ref/src/renderer/shaders/shadertoy_prefix.glsl"

if command -v glslangValidator > /dev/null 2>&1; then
    glslang_bin="glslangValidator"
elif command -v glslang > /dev/null 2>&1; then
    glslang_bin="glslang"
else
    echo "glslangValidator not found. Run: brew install glslang spirv-cross" >&2
    exit 1
fi
if ! command -v spirv-cross > /dev/null 2>&1; then
    echo "spirv-cross not found. Run: brew install glslang spirv-cross" >&2
    exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-saver-custom.XXXXXXXX")"
trap 'rm -r -- "$work_dir" 2> /dev/null || true' EXIT

prefix_file="$work_dir/prefix.glsl"
if [ -n "${GHOSTTY_SAVER_PREFIX_FILE:-}" ]; then
    if [ ! -f "$GHOSTTY_SAVER_PREFIX_FILE" ]; then
        echo "GHOSTTY_SAVER_PREFIX_FILE=$GHOSTTY_SAVER_PREFIX_FILE does not exist." >&2
        exit 1
    fi
    cp "$GHOSTTY_SAVER_PREFIX_FILE" "$prefix_file"
else
    if ! curl -fsSL "$prefix_url" -o "$prefix_file"; then
        echo "could not fetch $prefix_url" >&2
        echo "Offline? Set GHOSTTY_SAVER_PREFIX_FILE to a local copy." >&2
        exit 1
    fi
fi

if [ $# -gt 0 ]; then
    files=("$@")
else
    files=("$repo_root"/custom-shaders/*.glsl)
fi

for glsl in "${files[@]}"; do
    stem="$(basename "$glsl" .glsl)"
    cat "$prefix_file" "$glsl" > "$work_dir/$stem.frag"
    if ! "$glslang_bin" -V -S frag "$work_dir/$stem.frag" -o "$work_dir/$stem.spv" > "$work_dir/$stem.log" 2>&1; then
        echo "glslang rejected $glsl" >&2
        cat "$work_dir/$stem.log" >&2
        exit 1
    fi
    if ! spirv-cross --msl --msl-decoration-binding "$work_dir/$stem.spv" > "$work_dir/$stem.metal" 2> "$work_dir/$stem.log"; then
        echo "spirv-cross rejected $glsl" >&2
        cat "$work_dir/$stem.log" >&2
        exit 1
    fi
    echo "ok: $glsl"
done
