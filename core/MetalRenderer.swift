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
            return "no Metal device available"
        case .noCommandQueue:
            return "could not create an MTLCommandQueue"
        case .libraryCompilation(let message):
            return "shader compilation failed: \(message)"
        case .missingFunction(let name):
            return "shader function \(name) not found"
        case .pipelineCreation(let message):
            return "could not create the render pipeline: \(message)"
        case .bufferCreation:
            return "could not wrap the shared memory in an MTLBuffer"
        case .textureCreation(let bytesPerRow, let alignment):
            return "could not create the texture (bytesPerRow=\(bytesPerRow) is not \(alignment)-byte aligned)"
        case .encoderCreation:
            return "could not create a render command encoder"
        case .commandFailure(let message):
            return "GPU command failed: \(message)"
        case .frameTooSmall(let needed, let actual):
            return "shared memory is too small (need \(needed) bytes, have \(actual))"
        }
    }
}

/// Vertex shader that covers the screen with a single triangle. There is no
/// geometry to speak of. It is concatenated with the fragment shader and
/// compiled as one MSL source.
public let saverVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct SaverVertexOut {
    float4 position [[position]];
};

vertex SaverVertexOut saver_vertex(uint vertexID [[vertex_id]]) {
    // vertexID 0,1,2 -> (0,0), (2,0), (0,2), stretched into NDC so the triangle
    // covers the whole viewport.
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    SaverVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return out;
}
"""

/// Renders straight into a shared memory render target.
///
/// The region returned by shm_open is wrapped with makeBuffer(bytesNoCopy:) and
/// turned into a texture with makeTexture(descriptor:offset:bytesPerRow:), so
/// what the GPU draws lands in shared memory with no readback copy.
public final class MetalRenderer {
    public static let pixelFormat: MTLPixelFormat = .rgba8Unorm

    public let device: MTLDevice
    /// Width after padding. The texture and the shared memory both use this.
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var bytesPerRow: Int
    public var payloadBytes: Int { bytesPerRow * height }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let linearAlignment: Int
    /// Where Ghostty binds the terminal's own image. Here it is a 1x1 black
    /// texture.
    private let channel0: MTLTexture
    private let channel0Sampler: MTLSamplerState

    /// A linear texture backed by a buffer **traps** when bytesPerRow does not
    /// meet the device's alignment - it does not return nil. This rounds the
    /// width up to the nearest value that satisfies it.
    public static func alignedWidth(_ width: Int, device: MTLDevice) -> Int {
        let alignment = max(4, device.minimumLinearTextureAlignment(for: pixelFormat))
        let pixelsPerUnit = max(1, alignment / 4)
        return (width + pixelsPerUnit - 1) / pixelsPerUnit * pixelsPerUnit
    }

    /// - Parameters:
    ///   - requestedWidth: the terminal's pixel width, rounded up internally.
    ///   - fragmentSource: MSL for the fragment shader. The vertex shader is
    ///     prepended automatically.
    ///   - fragmentFunctionName: entry point inside fragmentSource.
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

    /// Adopts a new terminal size. The pipeline does not depend on the size,
    /// so a resize does not mean recompiling the shader.
    public func resize(width requestedWidth: Int, height newHeight: Int) {
        width = Self.alignedWidth(requestedWidth, device: device)
        height = newHeight
        bytesPerRow = width * 4
    }

    /// A 1x1 black texture. Binding it is harmless for shaders that never touch
    /// iChannel0.
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

    /// Draws one frame with shared memory as the render target. The GPU is
    /// waited on, so the shared memory holds a finished frame when this returns.
    ///
    /// spirv-cross places the uniform block at binding 1, so it is bound to
    /// buffer(1) - Ghostty puts it in the same place via
    /// MSL_ENABLE_DECORATION_BINDING.
    public func render(into frame: ShmFrame, uniforms: UniformBuffer) throws {
        guard frame.mappedBytes >= payloadBytes else {
            throw MetalRendererError.frameTooSmall(needed: payloadBytes, actual: frame.mappedBytes)
        }
        guard bytesPerRow % linearAlignment == 0 else {
            throw MetalRendererError.textureCreation(bytesPerRow: bytesPerRow, alignment: linearAlignment)
        }

        // mmap returns a page-aligned pointer, which is what bytesNoCopy needs.
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
