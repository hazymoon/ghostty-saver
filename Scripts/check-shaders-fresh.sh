#!/usr/bin/env bash
# @file check-shaders-fresh.sh
# @brief Fail if shaders/ changed without Scripts/build-shaders.sh being re-run
# @description
#   Generated/Shaders.swift is committed and nothing in the build compiles a
#   shader, so an edited .glsl with a stale generated file passes every test:
#   the suite reads the old MSL and agrees with itself. This compares the
#   hash build-shaders.sh recorded in the generated header with the hash of
#   what is in shaders/ now.
#
#   It needs neither glslang nor spirv-cross, which is the point: re-running
#   the conversion on CI would need both tools at the exact versions that
#   produced the committed file, and Homebrew cannot pin them.
#
# @section Usage
#   Scripts/check-shaders-fresh.sh
#
# @exitcode 0 the generated file matches shaders/
# @exitcode 1 it does not, or carries no hash at all

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated="$repo_root/Generated/Shaders.swift"

recorded="$(sed -n 's|^// shaders-sha256: \([0-9a-f]*\)$|\1|p' "$generated" | head -1)"
if [ -z "$recorded" ]; then
    echo "Generated/Shaders.swift carries no shaders-sha256 line; run Scripts/build-shaders.sh." >&2
    exit 1
fi

current="$("$repo_root/Scripts/shader-sources-hash.sh")"
if [ "$recorded" != "$current" ]; then
    echo "shaders/ changed without re-running Scripts/build-shaders.sh:" >&2
    echo "  recorded $recorded" >&2
    echo "  current  $current" >&2
    exit 1
fi

echo "Generated/Shaders.swift matches shaders/ ($current)"
