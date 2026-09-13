// swift-tools-version: 6.0
import PackageDescription

// Runs the production PTP code against fixtures without building/signing the App
// or booting an iOS simulator. It has no external package dependencies.
let package = Package(
    name: "ZTransferProtocol",
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: [
        .target(name: "ZTransferProtocol", path: "ZTransfer/Transport/PTP"),
        .target(name: "ZTransferGPS", path: "ZTransfer/Domain", sources: ["GPSProtocol.swift"]),
        .target(name: "ZTransferEffects", path: "ZTransfer/Domain", sources: ["PhotoEffects.swift", "PhotoEffectsBatch.swift", "Np3FilterEngine.swift", "Np3FilterCatalog.swift", "Np3BitmapFilter.swift"]),
        .target(name: "ZTransferRemote", path: "ZTransfer/Domain", sources: ["RemoteState.swift", "RemoteFrameParser.swift", "RemoteProperty.swift", "RemoteExposureParameters.swift", "RemoteDisplayOptions.swift", "RemoteMovieRecording.swift"]),
        .testTarget(name: "ProtocolTests", dependencies: ["ZTransferProtocol"], path: "ProtocolTests"),
        .testTarget(name: "GPSTests", dependencies: ["ZTransferGPS"], path: "GPSTests"),
        .testTarget(name: "RemoteTests", dependencies: ["ZTransferRemote"], path: "RemoteTests"),
        .testTarget(name: "EffectsTests", dependencies: ["ZTransferEffects"], path: "EffectsTests"),
    ]
)
