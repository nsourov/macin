// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacFootprint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacFootprint", targets: ["MacFootprint"]),
        .library(name: "FootprintCore", targets: ["FootprintCore"])
    ],
    targets: [
        .target(
            name: "FootprintCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MacFootprint",
            dependencies: ["FootprintCore"]
        ),
        .testTarget(
            name: "FootprintCoreTests",
            dependencies: ["FootprintCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
