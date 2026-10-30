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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "LoadTube",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/LoadTube",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
