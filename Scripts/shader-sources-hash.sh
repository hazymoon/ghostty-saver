#!/usr/bin/env bash
# @file shader-sources-hash.sh
# @brief One hash over every shader source, so a stale Generated/Shaders.swift can be told apart
# @description
#   Prints the SHA-256 of every shaders/**/*.glsl, taken in sorted path order
#   as path, NUL, contents. build-shaders.sh records the result in the header
#   of Generated/Shaders.swift and check-shaders-fresh.sh compares against it.
#
#   Recursive on purpose: a shared shaders/lib/ is part of every shader's
#   input, so a change there has to count as a change to all of them.
#
# @section Usage
#   Scripts/shader-sources-hash.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"
find shaders -type f -name '*.glsl' | LC_ALL=C sort | while IFS= read -r path; do
    printf '%s\0' "$path"
    cat "$path"
done | shasum -a 256 | awk '{print $1}'
