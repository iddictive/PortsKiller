// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PortsKiller",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PortsKiller", targets: ["PortsKiller"])
    ],
    targets: [
        .executableTarget(
            name: "PortsKiller",
            path: "Sources"
        ),
        .testTarget(
            name: "PortsKillerTests",
            dependencies: ["PortsKiller"],
            path: "Tests"
        )
    ]
)
