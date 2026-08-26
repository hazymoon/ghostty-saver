// このファイルは Scripts/build-shaders.sh が生成する。直接編集しない。
// 元データ: shaders/*.glsl と Ghostty の shadertoy_prefix.glsl

/// 1 本のシェーダの MSL と、その中のフラグメント関数名。
public struct ShaderProgram {
    public let name: String
    public let entryPoint: String
    public let source: String
}

/// Ghostty の shadertoy uniform ブロック（Globals）のバイトオフセット。
/// shaders/prefix.glsl から spirv-cross のリフレクション経由で生成している。
public enum ShadertoyUniformLayout {
    /// uniform バッファ全体のバイト数
    public static let size = 4492

    /// vec3
    public static let iResolution = 0

    /// float
    public static let iTime = 12

    /// float
    public static let iTimeDelta = 16

    /// float
    public static let iFrameRate = 20

    /// int
    public static let iFrame = 24

    /// float[4] / 要素間隔 16 バイト
    public static let iChannelTime = 32

    /// vec3[4] / 要素間隔 16 バイト
    public static let iChannelResolution = 96

    /// vec4
    public static let iMouse = 160

    /// vec4
    public static let iDate = 176

    /// float
    public static let iSampleRate = 192

    /// vec4
    public static let iCurrentCursor = 208

    /// vec4
    public static let iPreviousCursor = 224

    /// vec4
    public static let iCurrentCursorColor = 240

    /// vec4
    public static let iPreviousCursorColor = 256

    /// int
    public static let iCurrentCursorStyle = 272

    /// int
    public static let iPreviousCursorStyle = 276

    /// int
    public static let iCursorVisible = 280

    /// float
    public static let iTimeCursorChange = 284

    /// float
    public static let iTimeFocus = 288

    /// int
    public static let iFocus = 292

    /// vec3[256] / 要素間隔 16 バイト
    public static let iPalette = 304

    /// vec3
    public static let iBackgroundColor = 4400

    /// vec3
    public static let iForegroundColor = 4416

    /// vec3
    public static let iCursorColor = 4432

    /// vec3
    public static let iCursorText = 4448

    /// vec3
    public static let iSelectionForegroundColor = 4464

    /// vec3
    public static let iSelectionBackgroundColor = 4480
}

/// shaders/*.glsl から生成した MSL。
public enum GeneratedShaders {
    /// shaders/gradient.glsl から生成
    public static let gradient = ShaderProgram(
        name: "gradient",
        entryPoint: "main0",
        source: #"""
#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct Globals
{
    packed_float3 iResolution;
    float iTime;
    float iTimeDelta;
    float iFrameRate;
    int iFrame;
    float4 iChannelTime[4];
    float3 iChannelResolution[4];
    float4 iMouse;
    float4 iDate;
    float iSampleRate;
    float4 iCurrentCursor;
    float4 iPreviousCursor;
    float4 iCurrentCursorColor;
    float4 iPreviousCursorColor;
    int iCurrentCursorStyle;
    int iPreviousCursorStyle;
    int iCursorVisible;
    float iTimeCursorChange;
    float iTimeFocus;
    int iFocus;
    float3 iPalette[256];
    float3 iBackgroundColor;
    float3 iForegroundColor;
    float3 iCursorColor;
    float3 iCursorText;
    float3 iSelectionForegroundColor;
    float3 iSelectionBackgroundColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

static inline __attribute__((always_inline))
void mainImage(thread float4& fragColor, thread const float2& fragCoord, constant Globals& _38)
{
    float2 uv = fragCoord / float2(_38.iResolution[0], _38.iResolution[1]);
    float pulse = 0.5 + (0.5 * sin(_38.iTime * 2.0));
    fragColor = float4(uv.x, uv.y, pulse, 1.0);
}

fragment main0_out main0(constant Globals& _38 [[buffer(1)]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    float2 param_1 = gl_FragCoord.xy;
    float4 param;
    mainImage(param, param_1, _38);
    out._fragColor = param;
    return out;
}
"""#
    )
    /// 変換済みシェーダの一覧。名前で選ぶときに使う。
    public static let all: [ShaderProgram] = [gradient]
}
