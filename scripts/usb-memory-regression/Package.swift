// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "USBMemoryRegression", platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/ImageAllRemoteProtocol"),
                   .package(path: "../../Packages/ImageAllRemoteClient")],
    targets: [.executableTarget(name: "RecoveryProbe", dependencies: [
        .product(name: "ImageAllRemoteProtocol", package: "ImageAllRemoteProtocol")]),
        .executableTarget(name: "ResumeScenarioProbe", dependencies: [
            .product(name: "ImageAllRemoteProtocol", package: "ImageAllRemoteProtocol"),
            .product(name: "ImageAllRemoteClient", package: "ImageAllRemoteClient")])])
