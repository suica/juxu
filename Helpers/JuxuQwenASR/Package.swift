// swift-tools-version: 5.10
import Foundation
import PackageDescription

// JUXU_MLX_SWIFT_PATH points at a local mlx-swift 0.31.6 source tree for offline builds.
let mlxDependency: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["JUXU_MLX_SWIFT_PATH"], !path.isEmpty {
        return .package(name: "mlx-swift", path: path)
    }
    return .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6")
}()

let package = Package(
    name: "JuxuQwenASR",
    platforms: [.macOS("14.0")],
    products: [.executable(name: "juxu-qwen-asr", targets: ["juxu-qwen-asr"])],
    dependencies: [mlxDependency],
    targets: [
        .executableTarget(
            name: "juxu-qwen-asr",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
    ]
)
