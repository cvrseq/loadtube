// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LoadTube",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LoadTube", targets: ["LoadTube"])
    ],
    targets: [
        .executableTarget(
            name: "LoadTube",
            path: "Sources/LoadTube"
        )
    ]
)
