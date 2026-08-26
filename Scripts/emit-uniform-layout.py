"""Emit the uniform block's byte offsets as Swift, from spirv-cross reflection.

Mirrors the member names and offsets of the Globals block declared by Ghostty's
shadertoy_prefix.glsl. Generating them instead of writing them by hand means
moving the pinned reference keeps everything in sync on its own.

Called from build-shaders.sh.
"""

import json
import sys


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: emit-uniform-layout.py <spirv-cross --reflect JSON>")

    with open(sys.argv[1]) as handle:
        reflection = json.load(handle)

    globals_ubo = next(
        (u for u in reflection.get("ubos", []) if u.get("name") == "Globals"), None
    )
    if globals_ubo is None:
        sys.exit("no Globals block in the reflection output")

    members = reflection["types"][globals_ubo["type"]]["members"]

    lines = [
        "/// Byte offsets into Ghostty's shadertoy uniform block (Globals).",
        "/// Generated from shaders/prefix.glsl via spirv-cross reflection.",
        "public enum ShadertoyUniformLayout {",
        "    /// Total size of the uniform buffer.",
        f"    public static let size = {globals_ubo['block_size']}",
    ]

    for member in members:
        array = member.get("array")
        if array:
            comment = f"{member['type']}[{array[0]}], stride {member.get('array_stride')} bytes"
        else:
            comment = member["type"]
        lines.append("")
        lines.append(f"    /// {comment}")
        lines.append(f"    public static let {member['name']} = {member['offset']}")

    lines.append("}")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
