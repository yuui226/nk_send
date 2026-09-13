import Foundation
import Combine

/// Persisted names and defaults mirror PhotoFrameExporter.kt.  The renderer and
/// settings UI both consume these values so a draft can never silently change a
/// queued task's output.
enum PhotoFramePreset: String, CaseIterable, Codable, Sendable {
    case mist = "MIST", cinema = "CINEMA", minimal = "MINIMAL", frosted = "FROSTED"
    case plaque = "PLAQUE", immersive = "IMMERSIVE", brandInset = "BRAND_INSET", brandGallery = "BRAND_GALLERY"
    case classicSignature = "CLASSIC_SIGNATURE", galleryMat = "GALLERY_MAT", colorArchive = "COLOR_ARCHIVE"
    case filmGallery = "FILM_GALLERY", filmEdge = "FILM_EDGE"
}

enum PhotoFrameWatermarkFont: String, CaseIterable, Codable, Sendable { case signature = "SIGNATURE", elegant = "ELEGANT", calligraphy = "CALLIGRAPHY", simple = "SIMPLE", bold = "BOLD" }
enum PhotoFrameWatermarkContent: String, Codable, Sendable { case text = "TEXT", image = "IMAGE" }
enum PhotoFrameWatermarkPosition: String, CaseIterable, Codable, Sendable {
    case auto = "AUTO", left = "LEFT", center = "CENTER", right = "RIGHT"
    case photoTopLeft = "PHOTO_TOP_LEFT", photoTopCenter = "PHOTO_TOP_CENTER", photoTopRight = "PHOTO_TOP_RIGHT"
    case photoCenter = "PHOTO_CENTER", photoBottomLeft = "PHOTO_BOTTOM_LEFT", photoBottomCenter = "PHOTO_BOTTOM_CENTER", photoBottomRight = "PHOTO_BOTTOM_RIGHT"
}
enum PhotoFrameWatermarkEffect: String, CaseIterable, Codable, Sendable { case auto = "AUTO", none = "NONE", shadow = "SHADOW", outline = "OUTLINE" }
enum PhotoFrameWatermarkColor: String, CaseIterable, Codable, Sendable { case adaptive = "ADAPTIVE", white = "WHITE", black = "BLACK", gold = "GOLD", mistBlue = "MIST_BLUE", roseGold = "ROSE_GOLD" }

struct PhotoFrameWatermark: Codable, Equatable, Sendable {
    static let defaultText = "ZTransfer"
    static let maxTextLength = 24
    var enabled = true
    var content: PhotoFrameWatermarkContent = .text
    var text = PhotoFrameWatermark.defaultText
    var imageHash: String?
    var font: PhotoFrameWatermarkFont = .calligraphy
    var sizePercent = 80
    var position: PhotoFrameWatermarkPosition = .auto
    var color: PhotoFrameWatermarkColor = .adaptive
    var opacityPercent = 72
    var effect: PhotoFrameWatermarkEffect = .auto

    var displayText: String {
        let normalized = text.replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
            .filter { !$0.isNewline && !$0.isWhitespace || $0 == " " }
        let trimmed = String(normalized.prefix(Self.maxTextLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultText : trimmed
    }
}

struct PhotoFrameMetadataSettings: Codable, Equatable, Sendable {
    var showDate = true
    var showTime = true
    var showFocalLength = true
    var showExposure = true
    var showBrand = true
    var showModel = true
    var showLensModel = false
    var showCoordinates = false
    var showAltitude = false
    var datePattern = "yyyy-MM-dd"
    var timePattern = "HH:mm:ss"

    static func defaults(for preset: PhotoFramePreset) -> Self {
        var value = Self()
        switch preset {
        case .classicSignature:
            value.showDate = false; value.showTime = false; value.showModel = false
        case .galleryMat, .filmEdge:
            value.showDate = false; value.showTime = false; value.showFocalLength = false; value.showExposure = false; value.showBrand = false; value.showModel = false
        case .colorArchive:
            value.showDate = false; value.showTime = false; value.showModel = true
        case .filmGallery:
            value.showDate = true; value.showTime = true; value.showFocalLength = false; value.showExposure = false
        case .plaque:
            value.showDate = true; value.showTime = true
        default:
            value.showDate = false; value.showTime = false; value.showModel = ![.brandInset, .brandGallery].contains(preset)
        }
        return value
    }
}

struct PhotoFilterPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct PhotoFilterSelection: Codable, Equatable, Sendable {
    let preset: PhotoFilterPreset
    var intensityPercent: Int
    var normalizedIntensityPercent: Int { Np3FilterEngine.normalizeIntensity(intensityPercent) }
}

/// Metadata, identity and ordering come from Android's curated NP3 catalog.
enum PhotoFilterCatalog {
    static let presets = Np3FilterCatalog.presets.map { PhotoFilterPreset(id: $0.id, name: $0.name) }

    static func resolve(_ id: String) -> PhotoFilterPreset? {
        Np3FilterCatalog.preset(id: id).map { PhotoFilterPreset(id: $0.id, name: $0.name) }
    }
}

struct PhotoEffectsSettings: Codable, Equatable, Sendable {
    var photoFrameEnabled = false
    var photoFrameBorderEnabled = true
    var photoFramePreset: PhotoFramePreset = .mist
    var watermark = PhotoFrameWatermark()
    var metadata = PhotoFrameMetadataSettings()
    var photoFilterEnabled = false
    var selectedFilter: PhotoFilterSelection?

    var hasEffect: Bool {
        photoFrameEnabled || (photoFilterEnabled && selectedFilter != nil)
    }
}

@MainActor
final class PhotoEffectsStore: ObservableObject {
    @Published private(set) var settings: PhotoEffectsSettings
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, scope: Scope = .cameraTransfer) {
        self.defaults = defaults
        key = scope == .cameraTransfer ? "photoEffectsSettings.v1" : "localPhotoEffectsSettings.v1"
        if let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(PhotoEffectsSettings.self, from: data) {
            settings = Self.normalized(value)
        } else {
            settings = PhotoEffectsSettings()
            if scope == .localPhotos, let first = PhotoFilterCatalog.presets.first {
                settings.selectedFilter = .init(preset: first, intensityPercent: Np3FilterEngine.defaultIntensityPercent)
            }
        }
    }

    func update(_ value: PhotoEffectsSettings) {
        settings = Self.normalized(value)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    func beginDraft() -> PhotoEffectsSettings { settings }

    /// Android LocalPhotoEffectsPreferences is separate from TransferState.
    /// Reuse the model and editor, while preserving their independent choices.
    enum Scope { case cameraTransfer, localPhotos }

    private static func normalized(_ value: PhotoEffectsSettings) -> PhotoEffectsSettings {
        var result = value
        if let selected = value.selectedFilter {
            if let preset = PhotoFilterCatalog.resolve(selected.preset.id) {
                result.selectedFilter = .init(preset: preset, intensityPercent: selected.normalizedIntensityPercent)
            } else {
                result.selectedFilter = nil
                result.photoFilterEnabled = false
            }
        }
        return result
    }
}
