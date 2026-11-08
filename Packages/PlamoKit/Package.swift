// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlamoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlamoKit", targets: ["PlamoKit"]),
        .executable(name: "plamo-cli", targets: ["plamo-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3")
    ],
    targets: [
        .target(
            name: "PlamoKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "plamo-cli",
            dependencies: ["PlamoKit", .product(name: "MLX", package: "mlx-swift")]
        ),
        .testTarget(
            name: "PlamoKitTests",
            dependencies: ["PlamoKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
