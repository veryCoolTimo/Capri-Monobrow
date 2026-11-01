// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Хелпер распознавания речи для Capri: transcribe.cpp (MIT) на закреплённом коммите, Swift-биндинг из его
// репозитория. Путь к клону даёт scripts/build-asr-macos.sh (CAPRI_TRANSCRIBE_SWIFT) — сам клон в кэше Мака,
// не в этом репозитории.
let bindings = Context.environment["CAPRI_TRANSCRIBE_SWIFT"] ?? "../../.transcribe/bindings/swift"

let package = Package(
    name: "capri-asr",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: bindings)],
    targets: [
        .executableTarget(
            name: "capri-asr",
            dependencies: [.product(name: "TranscribeCpp", package: "swift")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
