// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumacamCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(
            name: "LumaCamCore",
            targets: ["LumaCamCore"]
        ),
        .library(
            name: "NativeRTSP",
            targets: ["NativeRTSP"]
        ),
    ],
    targets: [
        .target(
            name: "LumaCamCore",
            path: "packages/LumaCamCore/Sources/LumaCamCore"
        ),
        .target(
            name: "NativeRTSP",
            dependencies: ["LumaCamCore"],
            path: "packages/NativeRTSP/Sources/NativeRTSP"
        ),
        .testTarget(
            name: "LumaCamCoreTests",
            dependencies: ["LumaCamCore"],
            path: "packages/LumaCamCore/Tests/LumaCamCoreTests"
        ),
        .testTarget(
            name: "NativeRTSPTests",
            dependencies: ["NativeRTSP", "LumaCamCore"],
            path: "packages/NativeRTSP/Tests/NativeRTSPTests",
            resources: [.process("Fixtures")]
        ),
    ]
)
