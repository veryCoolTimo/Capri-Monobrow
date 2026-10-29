// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Capri",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Capri", targets: ["Capri"])],
    targets: [
        .target(name: "CapriKit"),
        .executableTarget(name: "Capri", dependencies: ["CapriKit"], resources: [.copy("Resources/Character")]),
        .testTarget(name: "CapriKitTests", dependencies: ["CapriKit"])
    ],
    swiftLanguageModes: [.v5]
)
