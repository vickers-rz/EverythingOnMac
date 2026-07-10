// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "EverythingOnMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EverythingOnMac", targets: ["EverythingOnMac"]),
        .library(name: "EverythingOnMacCore", targets: ["EverythingOnMacCore"]),
    ],
    targets: [
        .target(
            name: "CSearchFS"
        ),
        .target(
            name: "EverythingOnMacCore",
            dependencies: ["CSearchFS"]
        ),
        .executableTarget(
            name: "EverythingOnMac",
            dependencies: ["EverythingOnMacCore"]
        ),
        .testTarget(
            name: "EverythingOnMacTests",
            dependencies: ["EverythingOnMacCore", "EverythingOnMac"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
