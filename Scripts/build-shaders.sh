#!/usr/bin/env bash
# @file build-shaders.sh
# @brief Convert Shadertoy-style GLSL to MSL and embed it as Swift string literals
# @description
#   For every shaders/*.glsl, prepend the same uniform declarations Ghostty
#   uses and the shared helpers in shaders/lib/, compile to SPIR-V with
#   glslangValidator, and convert to MSL with spirv-cross.
#
#   shaders/lib/*.glsl is prepended to every shader, unconditionally. There is
#   no per-shader declaration of what it uses: glslang and spirv-cross drop
#   functions nothing references, so an unused helper never reaches the MSL.
#
#   Ghostty reads exactly one file for a custom-shader and resolves no
#   #include, so a shader that calls into the library is no longer a file that
#   can be pointed at directly. For each shader the same loop therefore also
#   writes a self-contained variant - library plus shader, without the prefix
#   Ghostty supplies itself - to .build/custom-shaders/<name>.glsl. That is
#   the file a custom-shader should name. It is build output, not committed.
#
#   Dropping the same .glsl into Ghostty's custom-shader and having it work is a
#   design goal, so the prepended declarations are Ghostty's own
#   shadertoy_prefix.glsl rather than a transcription of it. It is fetched from
#   a pinned tag into a temporary directory rather than kept here, so no
#   Ghostty source is carried in this repository or in the build output.
#
#   Set GHOSTTY_SAVER_PREFIX_FILE to a local copy to work without a network,
#   or GHOSTTY_SAVER_PREFIX_REF to move the pin.
#
#   Uniform offsets are generated from spirv-cross reflection instead of being
#   written by hand.
#
#   Generated/Shaders.swift is committed, so a build that does not change any
#   shader needs neither this script nor the conversion tools. Its header
#   records a hash of shaders/ (Scripts/shader-sources-hash.sh) so that
#   check-shaders-fresh.sh, and CI through it, can tell an edited .glsl from
#   a regenerated one without the tools.
#
# @section Dependencies
#   brew install glslang spirv-cross
#
# @section Usage
#   Scripts/build-shaders.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shader_dir="$repo_root/shaders"
lib_dir="$shader_dir/lib"
output_file="$repo_root/Generated/Shaders.swift"
custom_dir="$repo_root/.build/custom-shaders"
# Where the uniform declarations come from. Pinned to a tag so it cannot move
# underneath a build.
ghostty_ref="${GHOSTTY_SAVER_PREFIX_REF:-v1.3.1}"
prefix_url="https://raw.githubusercontent.com/ghostty-org/ghostty/$ghostty_ref/src/renderer/shaders/shadertoy_prefix.glsl"

# @description Locate the conversion tools. glslang ships under two names.
resolve_tools() {
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

    if ! command -v python3 > /dev/null 2>&1; then
        echo "python3 not found (needed to generate the uniform offsets)." >&2
        exit 1
    fi

    if [ -z "${GHOSTTY_SAVER_PREFIX_FILE:-}" ] && ! command -v curl > /dev/null 2>&1; then
        echo "curl not found. Set GHOSTTY_SAVER_PREFIX_FILE to a local copy of" >&2
        echo "shadertoy_prefix.glsl instead." >&2
        exit 1
    fi
}

# @description Turn a file name into a Swift identifier. matrix.glsl -> matrix
# @arg $1 string file name without its extension
swift_identifier() {
    python3 -c '
import re, sys
parts = [p for p in re.split(r"[^0-9A-Za-z]+", sys.argv[1]) if p]
print(parts[0].lower() + "".join(p.capitalize() for p in parts[1:]))
' "$1"
}

resolve_tools

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-saver-shaders.XXXXXXXX")"
trap 'rm -r -- "$work_dir" 2> /dev/null || true' EXIT

prefix_file="$work_dir/prefix.glsl"
if [ -n "${GHOSTTY_SAVER_PREFIX_FILE:-}" ]; then
    if [ ! -f "$GHOSTTY_SAVER_PREFIX_FILE" ]; then
        echo "GHOSTTY_SAVER_PREFIX_FILE=$GHOSTTY_SAVER_PREFIX_FILE does not exist." >&2
        exit 1
    fi
    cp "$GHOSTTY_SAVER_PREFIX_FILE" "$prefix_file"
    echo "uniform declarations: $GHOSTTY_SAVER_PREFIX_FILE"
else
    echo "fetching uniform declarations: $prefix_url"
    if ! curl -fsSL "$prefix_url" -o "$prefix_file"; then
        echo "could not fetch $prefix_url" >&2
        echo "Offline? Set GHOSTTY_SAVER_PREFIX_FILE to a local copy." >&2
        exit 1
    fi
fi

mkdir -p "$(dirname "$output_file")" "$custom_dir"

# The shared helpers, in a fixed order so the output does not depend on the
# filesystem. Nothing here today depends on the order, but a helper that
# calls another one would.
lib_file="$work_dir/lib.glsl"
: > "$lib_file"
if [ -d "$lib_dir" ]; then
    for lib in $(ls "$lib_dir"/*.glsl 2> /dev/null | LC_ALL=C sort); do
        cat "$lib" >> "$lib_file"
        echo >> "$lib_file"
    done
fi

shader_entries=""
layout_swift=""
identifiers=""

for glsl in "$shader_dir"/*.glsl; do
    stem="$(basename "$glsl" .glsl)"

    identifier="$(swift_identifier "$stem")"
    echo "converting: $stem -> $identifier"

    # 1. Prepend the uniform declarations, the main() wrapper and the shared
    #    helpers to make a complete GLSL fragment shader.
    cat "$prefix_file" "$lib_file" "$glsl" > "$work_dir/$stem.frag"

    # The same pieces minus the prefix are what Ghostty needs handed to it as
    # one file.
    {
        echo "// Generated by Scripts/build-shaders.sh from shaders/$stem.glsl"
        echo "// with shaders/lib/ prepended. Point Ghostty's custom-shader at"
        echo "// this file; shaders/$stem.glsl is the one to edit."
        echo
        cat "$lib_file" "$glsl"
    } > "$custom_dir/$stem.glsl"

    # 2. Compile to SPIR-V.
    if ! "$glslang_bin" -V -S frag "$work_dir/$stem.frag" -o "$work_dir/$stem.spv" > "$work_dir/$stem.glslang.log" 2>&1; then
        echo "glslang failed on $glsl" >&2
        cat "$work_dir/$stem.glslang.log" >&2
        exit 1
    fi

    # 3. Convert to MSL. --msl-decoration-binding matches what Ghostty passes
    #    (MSL_ENABLE_DECORATION_BINDING), which puts the uniform block at
    #    buffer(1).
    spirv-cross --msl --msl-decoration-binding "$work_dir/$stem.spv" > "$work_dir/$stem.metal"

    # spirv-cross renames the entry point (main -> main0), so read it back out
    # rather than assuming.
    entry_point="$(sed -n 's/^fragment [A-Za-z0-9_]* \([A-Za-z0-9_]*\)(.*/\1/p' "$work_dir/$stem.metal" | head -1)"
    if [ -z "$entry_point" ]; then
        echo "could not find the fragment entry point in the MSL for $stem." >&2
        exit 1
    fi

    # 4. Pull the uniform block's offsets out of reflection. The prefix is
    #    shared, so a mismatch means something is wrong on the generating side.
    spirv-cross --reflect --output "$work_dir/$stem.json" "$work_dir/$stem.spv"
    generated_layout="$(python3 "$repo_root/Scripts/emit-uniform-layout.py" "$work_dir/$stem.json")"
    if [ -z "$layout_swift" ]; then
        layout_swift="$generated_layout"
    elif [ "$layout_swift" != "$generated_layout" ]; then
        echo "the uniform layout for $stem disagrees with the other shaders." >&2
        exit 1
    fi

    entry="$(python3 "$repo_root/Scripts/emit-shader-entry.py" \
        "$identifier" "$stem" "$entry_point" "$work_dir/$stem.metal" "$glsl")"
    shader_entries="$shader_entries$entry
"
    if [ -z "$identifiers" ]; then
        identifiers="$identifier"
    else
        identifiers="$identifiers, $identifier"
    fi
done

if [ -z "$layout_swift" ]; then
    echo "no .glsl to convert in $shader_dir." >&2
    exit 1
fi

{
    echo "// Generated by Scripts/build-shaders.sh. Do not edit."
    echo "// Sources: shaders/*.glsl and Ghostty's shadertoy_prefix.glsl"
    echo "// shaders-sha256: $("$repo_root/Scripts/shader-sources-hash.sh")"
    echo "// prefix-ref: $ghostty_ref"
    echo ""
    echo "/// One shader's MSL plus the name of its fragment function."
    echo "public struct ShaderProgram {"
    echo "    public let name: String"
    echo "    /// What the shader draws, taken from its leading comment."
    echo "    public let summary: String"
    echo "    public let entryPoint: String"
    echo "    public let source: String"
    echo ""
    echo "    public init(name: String, summary: String, entryPoint: String, source: String) {"
    echo "        self.name = name"
    echo "        self.summary = summary"
    echo "        self.entryPoint = entryPoint"
    echo "        self.source = source"
    echo "    }"
    echo "}"
    echo ""
    echo "$layout_swift"
    echo ""
    echo "/// MSL generated from shaders/*.glsl."
    echo "public enum GeneratedShaders {"
    printf '%s' "$shader_entries"
    echo "    /// Every converted shader, for selecting one by name."
    echo "    public static let all: [ShaderProgram] = [$identifiers]"
    echo "}"
} > "$output_file"

echo "wrote: $output_file"
echo "custom-shader variants: $custom_dir/"
