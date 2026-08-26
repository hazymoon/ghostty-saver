// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ghostty-saver",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CShim", path: "cshim"),
        // Scripts/build-shaders.sh が shaders/*.glsl から生成する MSL
        .target(name: "GeneratedShaders", path: "Generated"),
        // 転送層・端末制御など spike と本体で共有する部分
        .target(name: "SaverCore", dependencies: ["CShim"], path: "core"),
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
    ]
)
