import Foundation
import Metal

public enum MetalRendererError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case libraryCompilation(String)
    case missingFunction(String)
    case pipelineCreation(String)
    case bufferCreation
    case textureCreation(bytesPerRow: Int, alignment: Int)
    case encoderCreation
    case commandFailure(String)
    case frameTooSmall(needed: Int, actual: Int)

    public var description: String {
        switch self {
        case .noDevice:
            return "Metal デバイスが見つかりません"
        case .noCommandQueue:
            return "MTLCommandQueue を作れません"
        case .libraryCompilation(let message):
            return "シェーダのコンパイルに失敗しました: \(message)"
        case .missingFunction(let name):
            return "シェーダ関数 \(name) が見つかりません"
        case .pipelineCreation(let message):
            return "レンダーパイプラインを作れません: \(message)"
        case .bufferCreation:
            return "共有メモリを MTLBuffer として包めません"
        case .textureCreation(let bytesPerRow, let alignment):
            return "テクスチャを作れません (bytesPerRow=\(bytesPerRow) が \(alignment) バイト境界にありません)"
        case .encoderCreation:
            return "レンダーコマンドエンコーダを作れません"
        case .commandFailure(let message):
            return "GPU コマンドが失敗しました: \(message)"
        case .frameTooSmall(let needed, let actual):
            return "共有メモリが小さすぎます (必要 \(needed) バイト、実際 \(actual) バイト)"
        }
    }
}

/// 画面全体を覆う三角形1枚を描く頂点シェーダ。ジオメトリは持たない。
/// フラグメントシェーダ側と結合して 1 つの MSL ソースとしてコンパイルする。
public let saverVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct SaverVertexOut {
    float4 position [[position]];
};

vertex SaverVertexOut saver_vertex(uint vertexID [[vertex_id]]) {
    // vertexID 0,1,2 -> (0,0), (2,0), (0,2) を NDC に伸ばして画面全体を覆う
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    SaverVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return out;
}
"""

/// 共有メモリ上のレンダーターゲットへ直接描く Metal レンダラ。
///
/// `shm_open` した領域を `makeBuffer(bytesNoCopy:)` で包み、そこから
/// `makeTexture(descriptor:offset:bytesPerRow:)` でテクスチャを作るので、
/// GPU の描画結果がそのまま共有メモリに載り readback のコピーが発生しない。
public final class MetalRenderer {
    public static let pixelFormat: MTLPixelFormat = .rgba8Unorm

    public let device: MTLDevice
    /// パディング後の幅。テクスチャと共有メモリはこの幅で扱う。
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public var payloadBytes: Int { bytesPerRow * height }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let linearAlignment: Int
    /// Ghostty では端末画像がバインドされる位置。本プログラムでは 1x1 の黒を渡す。
    private let channel0: MTLTexture
    private let channel0Sampler: MTLSamplerState

    /// バッファ由来の linear texture は `bytesPerRow` がデバイスの要求する境界に
    /// 乗っていないと**アサートで即死**する（nil が返るのではない）。
    /// 幅をその境界に切り上げた値を返す。
    public static func alignedWidth(_ width: Int, device: MTLDevice) -> Int {
        let alignment = max(4, device.minimumLinearTextureAlignment(for: pixelFormat))
        let pixelsPerUnit = max(1, alignment / 4)
        return (width + pixelsPerUnit - 1) / pixelsPerUnit * pixelsPerUnit
    }

    /// - Parameters:
    ///   - width: 端末のピクセル幅。境界に合うよう内部で切り上げる。
    ///   - fragmentSource: フラグメントシェーダの MSL。頂点シェーダは自動で前置する。
    ///   - fragmentFunctionName: fragmentSource 内のエントリポイント名。
    public init(
        width requestedWidth: Int,
        height: Int,
        fragmentSource: String,
        fragmentFunctionName: String
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalRendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalRendererError.noCommandQueue }
        self.device = device
        self.queue = queue

        self.linearAlignment = max(4, device.minimumLinearTextureAlignment(for: Self.pixelFormat))
        self.width = Self.alignedWidth(requestedWidth, device: device)
        self.height = height
        self.bytesPerRow = self.width * 4

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: saverVertexSource + "\n" + fragmentSource, options: nil)
        } catch {
            throw MetalRendererError.libraryCompilation("\(error)")
        }

        guard let vertexFunction = library.makeFunction(name: "saver_vertex") else {
            throw MetalRendererError.missingFunction("saver_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: fragmentFunctionName) else {
            throw MetalRendererError.missingFunction(fragmentFunctionName)
        }

        self.channel0 = try Self.makeBlackTexture(device: device)
        guard let sampler = device.makeSamplerState(descriptor: MTLSamplerDescriptor()) else {
            throw MetalRendererError.textureCreation(bytesPerRow: 0, alignment: 0)
        }
        self.channel0Sampler = sampler

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreation("\(error)")
        }
    }

    /// 1x1 の黒。iChannel0 を使わないシェーダでもバインドは害にならない。
    private static func makeBlackTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureCreation(bytesPerRow: 4, alignment: 0)
        }
        var black: UInt32 = 0xFF00_0000
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &black,
            bytesPerRow: 4
        )
        return texture
    }

    /// 共有メモリを直接レンダーターゲットにして 1 フレーム描く。
    /// GPU の完了を待ってから返るので、戻った時点で共有メモリの中身は確定している。
    ///
    /// uniform は spirv-cross が binding 1 に置くので buffer(1) に束ねる
    /// （Ghostty も MSL_ENABLE_DECORATION_BINDING で同じ位置に置いている）。
    public func render(into frame: ShmFrame, uniforms: UniformBuffer) throws {
        guard frame.mappedBytes >= payloadBytes else {
            throw MetalRendererError.frameTooSmall(needed: payloadBytes, actual: frame.mappedBytes)
        }
        guard bytesPerRow % linearAlignment == 0 else {
            throw MetalRendererError.textureCreation(bytesPerRow: bytesPerRow, alignment: linearAlignment)
        }

        // mmap の返り値はページ境界に整列しているので bytesNoCopy の要件を満たす。
        guard let buffer = device.makeBuffer(
            bytesNoCopy: frame.base,
            length: frame.mappedBytes,
            options: .storageModeShared,
            deallocator: nil
        ) else {
            throw MetalRendererError.bufferCreation
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget, .shaderRead]

        guard let texture = buffer.makeTexture(
            descriptor: textureDescriptor,
            offset: 0,
            bytesPerRow: bytesPerRow
        ) else {
            throw MetalRendererError.textureCreation(bytesPerRow: bytesPerRow, alignment: linearAlignment)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRendererError.encoderCreation
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(uniforms.buffer, offset: 0, index: 1)
        encoder.setFragmentTexture(channel0, index: 0)
        encoder.setFragmentSamplerState(channel0Sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalRendererError.commandFailure("\(error)")
        }
    }
}
