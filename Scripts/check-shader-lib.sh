#!/usr/bin/env bash
# @file check-shader-lib.sh
# @brief Fail on the two ways a shader and shaders/lib/ can silently fall out
# @description
#   Scripts/build-shaders.sh prepends every shaders/lib/*.glsl to every
#   shader, so two things that each look fine on their own break together:
#
#   - A shader that defines a function the library also defines. glslang
#     rejects the pair as "function already has a body", but only when the
#     shader is regenerated - a shader written before a helper moved into
#     the library, merged after, compiles nowhere until someone re-runs the
#     build. This lists every function the library defines and looks for a
#     second definition in shaders/*.glsl.
#
#   - A const array in the library. spirv-cross drops an unreferenced
#     function from the MSL but keeps a const array, so one array in lib/
#     lands in every shader's generated source. A function returning
#     literals is dropped like any other unused helper, so that is the form
#     tables take here.
#
#   Neither check needs glslang or spirv-cross, so CI can run it on every
#   pull request.
#
# @section Usage
#   Scripts/check-shader-lib.sh
#
# @exitcode 0 nothing is redefined and the library holds no const arrays
# @exitcode 1 otherwise, with each offender on its own line

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shader_dir="$repo_root/shaders"
lib_dir="$shader_dir/lib"

if [ ! -d "$lib_dir" ]; then
    echo "no shaders/lib/; nothing to check"
    exit 0
fi

# A GLSL function definition at column 0: return type, name, an open paren.
definition='^(void|bool|int|uint|float|[biu]?vec[234]|mat[234]) +([A-Za-z_][A-Za-z0-9_]*) *\('

failed=0

# @description Every function the library defines, one name per line.
lib_functions() {
    grep -hoE "$definition" "$lib_dir"/*.glsl | sed -E "s/$definition/\2/" | LC_ALL=C sort -u
}

while read -r name; do
    [ -n "$name" ] || continue
    for shader in "$shader_dir"/*.glsl; do
        if grep -qE "^(void|bool|int|uint|float|[biu]?vec[234]|mat[234]) +$name *\(" "$shader"; then
            echo "$(basename "$shader") defines $name(), which shaders/lib/ already defines; call the library's or rename it" >&2
            failed=1
        fi
    done
done < <(lib_functions)

for lib in "$lib_dir"/*.glsl; do
    if grep -nE '^const +[A-Za-z0-9_]+ +[A-Za-z_][A-Za-z0-9_]* *\[' "$lib" > /dev/null; then
        grep -nE '^const +[A-Za-z0-9_]+ +[A-Za-z_][A-Za-z0-9_]* *\[' "$lib" | while IFS=: read -r line text; do
            echo "shaders/lib/$(basename "$lib"):$line: const array in the library reaches every shader's MSL; make it a function returning literals ($text)" >&2
        done
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "shaders/lib/ defines $(lib_functions | wc -l | tr -d ' ') functions; no shader redefines one and the library holds no const arrays"
