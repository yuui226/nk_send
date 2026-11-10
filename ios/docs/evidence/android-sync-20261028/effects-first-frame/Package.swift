// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EffectsFirstFrame", platforms: [.macOS(.v13)], targets: [.target(name: "ZTransfer"), .testTarget(name: "EffectsTests", dependencies: ["ZTransfer"])], swiftLanguageModes: [.v5])
