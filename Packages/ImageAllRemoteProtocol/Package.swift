// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageAllRemoteProtocol",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "ImageAllRemoteProtocol",
            targets: ["ImageAllRemoteProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "ImageAllRemoteProtocol"
        ),
        .testTarget(
            name: "ImageAllRemoteProtocolTests",
            dependencies: ["ImageAllRemoteProtocol"]
        ),
    ]
)
