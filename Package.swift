// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Subline",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SublineCore", targets: ["SublineCore"]),
        .executable(name: "Subline", targets: ["Subline"])
    ],
    targets: [
        .target(name: "SublineCore"),
        .executableTarget(name: "Subline", dependencies: ["SublineCore"]),
        .testTarget(name: "SublineCoreTests", dependencies: ["SublineCore"])
    ]
)
