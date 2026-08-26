"""Emit one generated MSL shader as a Swift raw string literal.

Called from build-shaders.sh.
"""

import sys


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit("usage: emit-shader-entry.py <identifier> <stem> <entry point> <MSL path>")

    identifier, stem, entry_point, metal_path = sys.argv[1:5]
    with open(metal_path) as handle:
        source = handle.read().rstrip("\n")

    # Widen the delimiter until it cannot collide with the MSL body.
    pounds = "#"
    while pounds + '"""' in source or '"""' + pounds in source:
        pounds += "#"

    print(f"    /// Generated from shaders/{stem}.glsl")
    print(f"    public static let {identifier} = ShaderProgram(")
    print(f'        name: "{stem}",')
    print(f'        entryPoint: "{entry_point}",')
    # Swift strips indentation based on the closing delimiter, so keep it at
    # column zero and emit the MSL body as-is.
    print(f'        source: {pounds}"""')
    print(source)
    print(f'"""{pounds}')
    print("    )")


if __name__ == "__main__":
    main()
