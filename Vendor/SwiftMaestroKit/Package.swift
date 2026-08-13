// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftMaestroKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftMaestroKit", targets: ["SwiftMaestroKit"])
    ],
    dependencies: [
        .package(name: "mlx-swift-lm", path: "../mlx-swift-lm"),
        .package(path: "../swift-transformers"),
        .package(name: "mcp-swift-sdk", path: "../mcp-swift-sdk"),
    ],
    targets: [
        .target(
            name: "SwiftMaestroKit",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "MCP", package: "mcp-swift-sdk"),
            ]
        ),
        .testTarget(
            name: "SwiftMaestroKitTests",
            dependencies: ["SwiftMaestroKit"]
        ),
    ]
)
