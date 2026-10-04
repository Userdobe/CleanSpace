// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCleanUp",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacCleanUp", targets: ["MacCleanUpApp"])],
    targets: [.executableTarget(name: "MacCleanUpApp", path: "Sources/MacCleanUpApp", resources: [.process("cleanspace-icon.png")])]
)
