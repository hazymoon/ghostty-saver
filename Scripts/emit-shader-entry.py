"""Emit one generated MSL shader as a Swift raw string literal.

Called from build-shaders.sh.
"""

import re
import sys


def summarise(glsl_path: str) -> str:
    """The leading comment block of a shader, as one line.

    Every shader opens by saying what it draws, so that is what `--list-shaders`
    shows rather than a description kept somewhere else and left to rot. The
    block ends at the first bare `//`, which is the blank line the shaders use
    between the summary and the notes below it.
    """
    parts: list[str] = []
    with open(glsl_path) as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("//"):
                break
            text = line[2:].strip()
            if not text:
                break
            parts.append(text)
    return re.sub(r"\s+", " ", " ".join(parts))


def main() -> None:
    if len(sys.argv) != 6:
        sys.exit(
            "usage: emit-shader-entry.py <identifier> <stem> <entry point> "
            "<MSL path> <GLSL path>"
        )

    identifier, stem, entry_point, metal_path, glsl_path = sys.argv[1:6]
    with open(metal_path) as handle:
        source = handle.read().rstrip("\n")

    summary = summarise(glsl_path).replace("\\", "\\\\").replace('"', '\\"')

    # Widen the delimiter until it cannot collide with the MSL body.
    pounds = "#"
    while pounds + '"""' in source or '"""' + pounds in source:
        pounds += "#"

    print(f"    /// Generated from shaders/{stem}.glsl")
    print(f"    public static let {identifier} = ShaderProgram(")
    print(f'        name: "{stem}",')
    print(f'        summary: "{summary}",')
    print(f'        entryPoint: "{entry_point}",')
    # Swift strips indentation based on the closing delimiter, so keep it at
    # column zero and emit the MSL body as-is.
    print(f'        source: {pounds}"""')
    print(source)
    print(f'"""{pounds}')
    print("    )")


if __name__ == "__main__":
    main()
