#!/usr/bin/env bash
# @file build-shaders.sh
# @brief Shadertoy 形式の GLSL を MSL に変換し Swift の文字列リテラルとして埋め込む
# @description
#   shaders/*.glsl を対象に、Ghostty と同じ uniform 宣言を前置してから
#   glslangValidator で SPIR-V にし、spirv-cross で MSL に変換する。
#   同じ .glsl ファイルが Ghostty の custom-shader としてもそのまま動くことが
#   この構成の目的なので、前置する宣言は Ghostty の shadertoy_prefix.glsl を
#   使う。ただしこのリポジトリには取り込まず、実行時に固定のタグから取得する。
#   取得したものは一時ディレクトリに置き、成果物には含めない。
#
#   ネットワークを使いたくない場合は GHOSTTY_SAVER_PREFIX_FILE に手元の
#   shadertoy_prefix.glsl のパスを渡す。
#
#   uniform のオフセットは手書きせず spirv-cross のリフレクションから生成する。
#
#   生成物 Generated/Shaders.swift はコミットするため、シェーダを変更しない
#   ビルドではこのスクリプトも変換ツールも不要。
#
# @section 依存
#   brew install glslang spirv-cross
#
# @section 使い方
#   Scripts/build-shaders.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shader_dir="$repo_root/shaders"
output_file="$repo_root/Generated/Shaders.swift"
# 前置する uniform 宣言の取得元。タグに固定して勝手に変わらないようにする。
ghostty_ref="${GHOSTTY_SAVER_PREFIX_REF:-v1.3.1}"
prefix_url="https://raw.githubusercontent.com/ghostty-org/ghostty/$ghostty_ref/src/renderer/shaders/shadertoy_prefix.glsl"

# @description 変換ツールを解決する。glslang は配布によって実行ファイル名が異なる。
resolve_tools() {
    if command -v glslangValidator > /dev/null 2>&1; then
        glslang_bin="glslangValidator"
    elif command -v glslang > /dev/null 2>&1; then
        glslang_bin="glslang"
    else
        echo "glslangValidator が見つかりません。brew install glslang spirv-cross を実行してください。" >&2
        exit 1
    fi

    if ! command -v spirv-cross > /dev/null 2>&1; then
        echo "spirv-cross が見つかりません。brew install glslang spirv-cross を実行してください。" >&2
        exit 1
    fi

    if ! command -v python3 > /dev/null 2>&1; then
        echo "python3 が見つかりません（uniform のオフセット生成に使います）。" >&2
        exit 1
    fi

    if [ -z "${GHOSTTY_SAVER_PREFIX_FILE:-}" ] && ! command -v curl > /dev/null 2>&1; then
        echo "curl が見つかりません。GHOSTTY_SAVER_PREFIX_FILE に手元の" >&2
        echo "shadertoy_prefix.glsl のパスを渡してください。" >&2
        exit 1
    fi
}

# @description ファイル名から Swift の識別子を作る。matrix.glsl -> matrix
# @arg $1 string 拡張子を除いたファイル名
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
        echo "GHOSTTY_SAVER_PREFIX_FILE=$GHOSTTY_SAVER_PREFIX_FILE がありません。" >&2
        exit 1
    fi
    cp "$GHOSTTY_SAVER_PREFIX_FILE" "$prefix_file"
    echo "uniform 宣言: $GHOSTTY_SAVER_PREFIX_FILE"
else
    echo "uniform 宣言を取得中: $prefix_url"
    if ! curl -fsSL "$prefix_url" -o "$prefix_file"; then
        echo "取得に失敗しました: $prefix_url" >&2
        echo "オフラインなら GHOSTTY_SAVER_PREFIX_FILE に手元のパスを渡してください。" >&2
        exit 1
    fi
fi

mkdir -p "$(dirname "$output_file")"

shader_entries=""
layout_swift=""
identifiers=""

for glsl in "$shader_dir"/*.glsl; do
    stem="$(basename "$glsl" .glsl)"

    identifier="$(swift_identifier "$stem")"
    echo "変換中: $stem -> $identifier"

    # 1. uniform 宣言と main() ラッパを前置して完全な GLSL フラグメントシェーダにする
    cat "$prefix_file" "$glsl" > "$work_dir/$stem.frag"

    # 2. SPIR-V にする
    if ! "$glslang_bin" -V -S frag "$work_dir/$stem.frag" -o "$work_dir/$stem.spv" > "$work_dir/$stem.glslang.log" 2>&1; then
        echo "glslang が失敗しました: $glsl" >&2
        cat "$work_dir/$stem.glslang.log" >&2
        exit 1
    fi

    # 3. MSL に変換する
    spirv-cross --msl --msl-decoration-binding "$work_dir/$stem.spv" > "$work_dir/$stem.metal"

    # MSL のエントリポイント名は spirv-cross が付け替える（main -> main0）ので実物から拾う
    entry_point="$(sed -n 's/^fragment [A-Za-z0-9_]* \([A-Za-z0-9_]*\)(.*/\1/p' "$work_dir/$stem.metal" | head -1)"
    if [ -z "$entry_point" ]; then
        echo "$stem の MSL からフラグメントのエントリポイントを特定できませんでした。" >&2
        exit 1
    fi

    # 4. uniform ブロックのオフセットをリフレクションから取る。
    #    prefix は全シェーダ共通なので、レイアウトが食い違ったら生成側の不整合。
    spirv-cross --reflect --output "$work_dir/$stem.json" "$work_dir/$stem.spv"
    generated_layout="$(python3 "$repo_root/Scripts/emit-uniform-layout.py" "$work_dir/$stem.json")"
    if [ -z "$layout_swift" ]; then
        layout_swift="$generated_layout"
    elif [ "$layout_swift" != "$generated_layout" ]; then
        echo "$stem の uniform レイアウトが他のシェーダと一致しません。" >&2
        exit 1
    fi

    entry="$(python3 "$repo_root/Scripts/emit-shader-entry.py" \
        "$identifier" "$stem" "$entry_point" "$work_dir/$stem.metal")"
    shader_entries="$shader_entries$entry
"
    if [ -z "$identifiers" ]; then
        identifiers="$identifier"
    else
        identifiers="$identifiers, $identifier"
    fi
done

if [ -z "$layout_swift" ]; then
    echo "変換対象の .glsl が $shader_dir にありません。" >&2
    exit 1
fi

{
    echo "// このファイルは Scripts/build-shaders.sh が生成する。直接編集しない。"
    echo "// 元データ: shaders/*.glsl と Ghostty の shadertoy_prefix.glsl"
    echo ""
    echo "/// 1 本のシェーダの MSL と、その中のフラグメント関数名。"
    echo "public struct ShaderProgram {"
    echo "    public let name: String"
    echo "    public let entryPoint: String"
    echo "    public let source: String"
    echo "}"
    echo ""
    echo "$layout_swift"
    echo ""
    echo "/// shaders/*.glsl から生成した MSL。"
    echo "public enum GeneratedShaders {"
    printf '%s' "$shader_entries"
    echo "    /// 変換済みシェーダの一覧。名前で選ぶときに使う。"
    echo "    public static let all: [ShaderProgram] = [$identifiers]"
    echo "}"
} > "$output_file"

echo "生成しました: $output_file"
