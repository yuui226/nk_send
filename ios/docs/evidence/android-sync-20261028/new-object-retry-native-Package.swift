// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ThumbnailRetryNative", platforms: [.macOS(.v13)], targets: [.target(name: "ZTransfer"), .testTarget(name: "ThumbnailTests", dependencies: ["ZTransfer"])], swiftLanguageModes: [.v5])
