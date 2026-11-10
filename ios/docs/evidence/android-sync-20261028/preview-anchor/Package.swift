// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PreviewAnchor", platforms: [.macOS(.v13)], targets: [.target(name: "ZTransfer"), .testTarget(name: "AnchorTests", dependencies: ["ZTransfer"])], swiftLanguageModes: [.v5])
