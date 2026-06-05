// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Yaotong",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Yaotong", targets: ["Yaotong"])
    ],
    targets: [
        .executableTarget(
            name: "Yaotong",
            path: "Sources/Yaotong"
        ),
        .testTarget(
            name: "YaotongTests",
            dependencies: ["Yaotong"],
            path: "Tests/YaotongTests"
        )
    ]
)
