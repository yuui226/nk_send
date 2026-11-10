// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ResourceParity", platforms: [.macOS(.v13)], targets: [.target(name: "ZTransfer"), .testTarget(name: "ResourceTests", dependencies: ["ZTransfer"])], swiftLanguageModes: [.v5])
