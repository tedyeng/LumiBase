// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumiBase",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "LumiBase",
            targets: ["LumiBase"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LumiBase",
            path: "LumiBase"
        ),
        .testTarget(
            name: "LumiBaseTests",
            dependencies: ["LumiBase"],
            path: "Tests/LumiBaseTests"
        )
    ]
)
