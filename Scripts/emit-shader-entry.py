"""生成した MSL を Swift の生文字列リテラルとして 1 エントリ分出力する。

build-shaders.sh から呼ばれる。
"""

import sys


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit("使い方: emit-shader-entry.py <識別子> <元ファイル名> <エントリポイント> <MSL のパス>")

    identifier, stem, entry_point, metal_path = sys.argv[1:5]
    with open(metal_path) as handle:
        source = handle.read().rstrip("\n")

    # 生文字列リテラルの区切りが MSL 本文と衝突しないよう # の数を増やす
    pounds = "#"
    while pounds + '"""' in source or '"""' + pounds in source:
        pounds += "#"

    print(f"    /// shaders/{stem}.glsl から生成")
    print(f"    public static let {identifier} = ShaderProgram(")
    print(f'        name: "{stem}",')
    print(f'        entryPoint: "{entry_point}",')
    # Swift の複数行文字列は「閉じ区切りのインデント」で本文を左詰めするため、
    # MSL 本文をそのまま出せるよう閉じ区切りは行頭に置く。
    print(f'        source: {pounds}"""')
    print(source)
    print(f'"""{pounds}')
    print("    )")


if __name__ == "__main__":
    main()
