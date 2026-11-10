import Foundation
#if SWIFT_PACKAGE
@testable import ZTransferEffects
#else
@testable import ZTransfer
#endif

/// Authored test data only. Tests enter the production user-import path with
/// owned snapshots; they never add recipes to the empty application catalog.
enum TestPhotoFilterCatalog {
    static let np3Presets: [Np3FilterPreset] = (0..<6).map { index in
        let digest = String(repeating: String(index + 1), count: 64)
        return .init(id: "np3:\(digest):np3-srgb-v1", catalogKey: "np3:" + digest,
            legacyID: "fixture_\(index)", name: "Test filter \(index)", fallbackName: "Test filter \(index)",
            parameters: .init(contrast: 20 + index * 5, saturation: 10 - index * 5,
                colorBands: Np3FilterParameters.colorBandCenters.map {
                    .init(centerDegrees: $0, hue: 0, chroma: 0, brightness: 0)
                }))
    }
    static let presets = np3Presets.map { PhotoFilterPreset(id: $0.id, name: $0.name) }
    static func recipe(id: String) -> PhotoNp3Recipe? {
        np3Presets.first { $0.id == id }.map {
            .init(preset: .init(id: $0.id, name: $0.name), parameters: .flexible($0.parameters))
        }
    }
}

func testPhotoFilterSelection(preset: PhotoFilterPreset, intensityPercent: Int = 80,
                              lutAdjustments: LUTAdjustments = .init()) -> PhotoFilterSelection {
    guard let recipe = TestPhotoFilterCatalog.recipe(id: preset.id) else {
        return .init(preset: preset, intensityPercent: intensityPercent, lutAdjustments: lutAdjustments)
    }
    return try! .init(np3Recipe: recipe, intensityPercent: intensityPercent, lutAdjustments: lutAdjustments)
}

extension PhotoEffectsSettings {
    mutating func selectTestFilter(_ id: String?) {
        if let id, let recipe = TestPhotoFilterCatalog.recipe(id: id) {
            precondition(selectPhotoFilter(recipe, explicit: true))
        } else { selectFilter(id) }
    }
}
