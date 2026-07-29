// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageAllRemoteClient",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "ImageAllRemoteClient",
            targets: ["ImageAllRemoteClient"]
        ),
    ],
    dependencies: [
        .package(path: "../ImageAllRemoteProtocol"),
    ],
    targets: [
        .target(
            name: "ImageAllRemoteClient",
            dependencies: [
                .product(name: "ImageAllRemoteProtocol", package: "ImageAllRemoteProtocol"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "ImageAllRemoteClientTests",
            dependencies: ["ImageAllRemoteClient"]
        ),
    ]
)
