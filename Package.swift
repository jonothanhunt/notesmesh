// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotesMesh",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "NotesMesh",
            path: "Sources/NotesMesh",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
