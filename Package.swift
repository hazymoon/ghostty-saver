// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ghostty-saver",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CShim", path: "cshim"),
        .executableTarget(
            name: "spike",
            dependencies: ["CShim"],
            path: "spike"
        ),
    ]
)
