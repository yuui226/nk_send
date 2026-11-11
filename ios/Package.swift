// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Runs the production PTP code against fixtures without building/signing the App
// or booting an iOS simulator. It has no external package dependencies.
let protocolOnly = ProcessInfo.processInfo.environment["ZTRANSFER_PROTOCOL_ONLY"] == "1"
let package = Package(
    name: "ZTransferProtocol",
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: protocolOnly ? [
        .target(name: "ZTransferProtocol", path: "ZTransfer/Transport/PTP"),
        .testTarget(name: "ProtocolTests", dependencies: ["ZTransferProtocol"], path: "ProtocolTests"),
    ] : [
        .target(name: "ZTransferProtocol", path: "ZTransfer/Transport/PTP"),
        .target(name: "ZTransferGPS", path: "ZTransfer/Domain", sources: ["GPSProtocol.swift"]),
        .target(name: "ZTransferNp3Native", path: "ThirdParty/PhotoNP3", sources: ["Np3ExactApply.cpp"], publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-std=c++17", "-O2", "-ffp-contract=off", "-fno-fast-math", "-fwrapv"])]),
        .target(name: "ZTransferEffects", dependencies: ["ZTransferNp3Native"], path: "ZTransfer/Domain", sources: ["PhotoCaptureExif.swift", "PhotoGrain.swift", "PhotoFrameUniformBorder.swift", "PhotoEffects.swift", "PhotoEffectsBatch.swift", "PhotoFrameTextLayout.swift", "Np3FilterEngine.swift", "Np3FilterCatalog.swift", "Np3BitmapFilter.swift", "PhotoNp3Recipe.swift", "PhotoNp3SnapshotCodec.swift", "PhotoFilterPreferences.swift", "PhotoNp3Parser.swift", "ClassicPhotoNp3Parser.swift", "CompiledFlexibleNp3.swift", "CompiledClassicNp3.swift", "CompiledNp3ColorGrading.swift", "LUTColorPipeline.swift"]),
        .target(name: "ZTransferRemote", path: "ZTransfer/Domain", sources: ["RemoteState.swift", "RemoteFrameParser.swift", "RemoteProperty.swift", "RemoteExposureParameters.swift", "RemoteDisplayOptions.swift", "RemoteMovieRecording.swift"]),
        .testTarget(name: "ProtocolTests", dependencies: ["ZTransferProtocol"], path: "ProtocolTests"),
        .testTarget(name: "GPSTests", dependencies: ["ZTransferGPS"], path: "GPSTests"),
        .testTarget(name: "RemoteTests", dependencies: ["ZTransferRemote"], path: "RemoteTests"),
        .testTarget(name: "EffectsTests", dependencies: ["ZTransferEffects"], path: "EffectsTests"),
    ]
)
