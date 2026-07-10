// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "EverythingOnMac",
    products: [
        .executable(name: "EverythingOnMac", targets: ["EverythingOnMac"]),
        .library(name: "EverythingOnMacCore", targets: ["EverythingOnMacCore"]),
    ],
    targets: [
        .target(
            name: "EverythingOnMacCore"
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
