// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageAllLocalLibrary",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "ImageAllLocalLibrary", targets: ["ImageAllLocalLibrary"])],
    targets: [
        .target(name: "ImageAllLocalLibrary", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "ImageAllLocalLibraryTests", dependencies: ["ImageAllLocalLibrary"])
    ]
)
