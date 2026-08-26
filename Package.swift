// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ghostty-saver",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CShim", path: "cshim"),
        // MSL that Scripts/build-shaders.sh generates from shaders/*.glsl.
        .target(name: "GeneratedShaders", path: "Generated"),
        // Transfer and terminal handling shared by the spike and the saver.
        .target(name: "SaverCore", dependencies: ["CShim", "GeneratedShaders"], path: "core"),
        .executableTarget(
            name: "spike",
            dependencies: ["SaverCore"],
            path: "spike"
        ),
        .executableTarget(
            name: "ghostty-saver",
            dependencies: ["SaverCore", "GeneratedShaders"],
            path: "saver"
        ),
        .testTarget(
            name: "SaverCoreTests",
            dependencies: ["SaverCore", "GeneratedShaders", "CShim"],
            path: "Tests/SaverCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
