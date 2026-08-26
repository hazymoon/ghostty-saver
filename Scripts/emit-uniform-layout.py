"""spirv-cross のリフレクション JSON から uniform ブロックのオフセットを Swift として出す。

Ghostty の shadertoy_prefix.glsl が定義する Globals ブロックのメンバ名とバイト
オフセットをそのまま写す。手書きしないことで、prefix を Ghostty の新しい版に
差し替えたときも自動で追従する。

build-shaders.sh から呼ばれる。
"""

import json
import sys


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("使い方: emit-uniform-layout.py <spirv-cross --reflect の JSON>")

    with open(sys.argv[1]) as handle:
        reflection = json.load(handle)

    globals_ubo = next(
        (u for u in reflection.get("ubos", []) if u.get("name") == "Globals"), None
    )
    if globals_ubo is None:
        sys.exit("リフレクションに Globals ブロックがありません")

    members = reflection["types"][globals_ubo["type"]]["members"]

    lines = [
        "/// Ghostty の shadertoy uniform ブロック（Globals）のバイトオフセット。",
        "/// shaders/prefix.glsl から spirv-cross のリフレクション経由で生成している。",
        "public enum ShadertoyUniformLayout {",
        "    /// uniform バッファ全体のバイト数",
        f"    public static let size = {globals_ubo['block_size']}",
    ]

    for member in members:
        array = member.get("array")
        if array:
            comment = f"{member['type']}[{array[0]}] / 要素間隔 {member.get('array_stride')} バイト"
        else:
            comment = member["type"]
        lines.append("")
        lines.append(f"    /// {comment}")
        lines.append(f"    public static let {member['name']} = {member['offset']}")

    lines.append("}")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
