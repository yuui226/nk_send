#if DEBUG
import Foundation

/// Synthetic controls for explicit UI-test fixtures, never an app catalog.
/// These parameters are authored here and contain no third-party filter data.
enum DebugPhotoFilterFixture {
    static func recipe(_ index: Int = 0) -> PhotoNp3Recipe {
        let digest = String(repeating: String(index + 1), count: 64)
        return .init(preset: .init(id: "np3:\(digest):np3-srgb-v1", name: "Imported fixture \(index + 1)"),
            parameters: .flexible(.init(contrast: 20 + index * 5, saturation: 10 - index * 5,
                colorBands: Np3FilterParameters.colorBandCenters.map {
                    .init(centerDegrees: $0, hue: 0, chroma: 0, brightness: 0)
                })))
    }
    static func apply(to settings: inout PhotoEffectsSettings) {
        _ = settings.selectPhotoFilter(recipe(), explicit: true)
    }
    static let folder = URL(fileURLWithPath: "/UITestNP3", isDirectory: true)
    static let files = (0..<4).map { index in
        let name = "Fixture\(index + 1).np3"
        return PresetFile(identifier: folder.appendingPathComponent(name).absoluteString,
                          name: name, relativePath: name, size: 256)
    }
    static var source: PhotoNp3Source {
        .init(scan: { _, ticket in
            try ticket.checkCancellation()
            return .init(bookmark: Data([1]), files: files, root: folder)
        }, read: { file, _, ticket in
            try ticket.checkCancellation()
            let value = recipe(files.firstIndex(where: { $0.identifier == file.identifier }) ?? 0)
            return .init(sourceSha256: PhotoNp3RecipeKind.sourceDigest(value.preset.id)!,
                         recipe: value, ignoredDetailControls: false)
        })
    }
}
#endif
