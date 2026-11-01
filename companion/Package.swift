// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrcaIsland",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OrcaIsland", targets: ["OrcaIsland"])
    ],
    targets: [
        .executableTarget(
            name: "OrcaIsland",
            path: "Sources/OrcaIsland"
        )
    ]
)
