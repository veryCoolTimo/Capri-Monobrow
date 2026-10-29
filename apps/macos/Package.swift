// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Capri",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Capri", targets: ["Capri"]),
        .executable(name: "CapriCollect", targets: ["CapriCollect"])
    ],
    targets: [
        .target(name: "CapriKit"),
        .executableTarget(name: "Capri", dependencies: ["CapriKit"], resources: [.copy("Resources/Character")]),
        .executableTarget(name: "CapriCollect", dependencies: ["CapriKit"]),
        .testTarget(name: "CapriKitTests", dependencies: ["CapriKit"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
