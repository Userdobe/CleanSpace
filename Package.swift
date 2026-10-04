// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCleanUp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacCleanUp", targets: ["MacCleanUpApp"]),
        .executable(name: "CleanSpaceDaemon", targets: ["CleanSpaceDaemon"])
    ],
    targets: [
        .executableTarget(name: "MacCleanUpApp", path: "Sources/MacCleanUpApp", resources: [.process("cleanspace-icon.png")]),
        .executableTarget(name: "CleanSpaceDaemon", path: "Sources/CleanSpaceDaemon")
    ]
)
