import Foundation
import Combine
import CryptoKit
import UIKit

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
enum PhotoFrameWatermarkContent: String, CaseIterable, Codable, Sendable { case text = "TEXT", image = "IMAGE" }
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

/// A frame favorite stores the complete watermark draft, matching Android's
/// FavoriteFrameWatermarkEffect rather than only remembering the frame name.
struct PhotoFrameFavorite: Codable, Equatable, Sendable {
    var preset: PhotoFramePreset
    var watermark: PhotoFrameWatermark
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
    var metadata = PhotoFrameMetadataSettings.defaults(for: .mist)
    /// Android keeps metadata overrides per frame preset. The legacy `metadata`
    /// value remains as the migration/default value for older iOS preferences.
    var metadataByPreset: [String: PhotoFrameMetadataSettings] = [:]
    var photoFilterEnabled = false
    var selectedFilter: PhotoFilterSelection?
    var filterIntensities: [String: Int] = [:]
    /// Android LocalPhotoEffectsPreferences persists favorites with the effect
    /// settings. Sets keep the same choices across workbench reopenings.
    var favoriteFilterIDs: Set<String> = []
    var favoriteFramePresets: Set<PhotoFramePreset> = []
    var favoriteFrameEffects: [PhotoFrameFavorite] = []

    var hasEffect: Bool {
        photoFrameEnabled || (photoFilterEnabled && selectedFilter != nil)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case photoFrameEnabled, photoFrameBorderEnabled, photoFramePreset, watermark,
             metadata, metadataByPreset, photoFilterEnabled, selectedFilter, filterIntensities, favoriteFilterIDs,
             favoriteFramePresets, favoriteFrameEffects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photoFrameEnabled = try c.decodeIfPresent(Bool.self, forKey: .photoFrameEnabled) ?? false
        photoFrameBorderEnabled = try c.decodeIfPresent(Bool.self, forKey: .photoFrameBorderEnabled) ?? true
        photoFramePreset = try c.decodeIfPresent(PhotoFramePreset.self, forKey: .photoFramePreset) ?? .mist
        watermark = try c.decodeIfPresent(PhotoFrameWatermark.self, forKey: .watermark) ?? PhotoFrameWatermark()
        metadata = try c.decodeIfPresent(PhotoFrameMetadataSettings.self, forKey: .metadata) ?? PhotoFrameMetadataSettings()
        metadataByPreset = try c.decodeIfPresent([String: PhotoFrameMetadataSettings].self, forKey: .metadataByPreset) ?? [:]
        photoFilterEnabled = try c.decodeIfPresent(Bool.self, forKey: .photoFilterEnabled) ?? false
        selectedFilter = try c.decodeIfPresent(PhotoFilterSelection.self, forKey: .selectedFilter)
        filterIntensities = try c.decodeIfPresent([String: Int].self, forKey: .filterIntensities) ?? [:]
        favoriteFilterIDs = try c.decodeIfPresent(Set<String>.self, forKey: .favoriteFilterIDs) ?? []
        favoriteFramePresets = try c.decodeIfPresent(Set<PhotoFramePreset>.self, forKey: .favoriteFramePresets) ?? []
        favoriteFrameEffects = try c.decodeIfPresent([PhotoFrameFavorite].self, forKey: .favoriteFrameEffects) ?? []
    }
}

@MainActor
final class PhotoEffectsStore: ObservableObject {
    @Published private(set) var settings: PhotoEffectsSettings
    private let defaults: UserDefaults
    private let key: String
    private let scope: Scope

    init(defaults: UserDefaults = .standard, scope: Scope = .cameraTransfer) {
        self.defaults = defaults
        self.scope = scope
        key = scope == .cameraTransfer ? "photoEffectsSettings.v1" : "localPhotoEffectsSettings.v1"
        if scope == .cameraTransfer, let value = Self.restoreAndroidTransferSettings(defaults: defaults) {
            settings = Self.normalized(value)
        } else if let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(PhotoEffectsSettings.self, from: data) {
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
        if scope == .cameraTransfer {
            Self.persistAndroidTransferSettings(settings, defaults: defaults)
        }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    func beginDraft() -> PhotoEffectsSettings { settings }

    /// Stores a watermark image in application support and returns its stable
    /// content hash, matching Android's private watermark copy semantics.
    func importWatermarkImage(_ image: UIImage) -> String? {
        guard let data = image.pngData() else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZTransfer/Watermarks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(hash).png"), options: .atomic)
            return hash
        } catch { return nil }
    }

    nonisolated static func watermarkImage(hash: String) -> UIImage? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZTransfer/Watermarks/\(hash).png")
        return (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
    }

    /// Android LocalPhotoEffectsPreferences is separate from TransferState.
    /// Reuse the model and editor, while preserving their independent choices.
    enum Scope { case cameraTransfer, localPhotos }

    private static func normalized(_ value: PhotoEffectsSettings) -> PhotoEffectsSettings {
        var result = value
        var watermark = value.watermark
        if watermark.content == .image && watermark.imageHash == nil { watermark.content = .text }
        watermark.sizePercent = min(max(watermark.sizePercent, 2), 100)
        watermark.opacityPercent = min(max(watermark.opacityPercent, 2), 100)
        result.watermark = watermark
        result.filterIntensities = value.filterIntensities.reduce(into: [:]) { partial, item in
            let key = Np3FilterCatalog.preset(id: item.key)?.catalogKey ?? item.key
            partial[key] = min(max(item.value, 2), 100)
        }
        result.favoriteFilterIDs = Set(value.favoriteFilterIDs.map { Np3FilterCatalog.preset(id: $0)?.catalogKey ?? $0 })
        if let selected = value.selectedFilter {
            if let preset = PhotoFilterCatalog.resolve(selected.preset.id) {
                result.selectedFilter = .init(preset: preset, intensityPercent: selected.normalizedIntensityPercent)
            } else {
                result.selectedFilter = nil
                result.photoFilterEnabled = false
            }
        }
        // Keep the old set field in sync for preferences written by the first
        // iOS workbench build, while the effect list remains the source of truth.
        result.favoriteFrameEffects = result.favoriteFrameEffects
            .reduce(into: [PhotoFramePreset: PhotoFrameFavorite]()) { partial, favorite in
                partial[favorite.preset] = favorite
            }
            .map { $0.value }
        let knownPresets = Set(result.favoriteFrameEffects.map(\.preset))
        for preset in result.favoriteFramePresets where !knownPresets.contains(preset) {
            result.favoriteFrameEffects.append(.init(preset: preset, watermark: result.watermark))
        }
        result.favoriteFramePresets.formUnion(result.favoriteFrameEffects.map(\.preset))
        return result
    }

    // MARK: Android preference compatibility

    /// Android keeps camera-transfer effects as individual entries in the
    /// `ztransfer` preferences file.  The first iOS implementation stored one
    /// private JSON blob, which made an existing Android configuration appear
    /// lost after switching platforms.  Read and write the Android keys
    /// directly; the old blob remains as a one-way fallback for upgrades.
    private static func restoreAndroidTransferSettings(defaults: UserDefaults) -> PhotoEffectsSettings? {
        let markerKeys = ["photo_frame_enabled", "photo_filter_selected_id", "photo_frame_preset",
                          "photo_frame_watermark_text", "favorite_photo_filters_v1"]
        guard markerKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        var value = PhotoEffectsSettings()
        value.photoFrameEnabled = defaults.object(forKey: "photo_frame_enabled") as? Bool ?? false
        value.photoFrameBorderEnabled = defaults.object(forKey: "photo_frame_border_enabled") as? Bool ?? true
        value.photoFramePreset = PhotoFramePreset(rawValue: defaults.string(forKey: "photo_frame_preset") ?? "MIST") ?? .mist
        value.photoFilterEnabled = defaults.object(forKey: "photo_filter_enabled") as? Bool ?? false
        let filterID = defaults.string(forKey: "photo_filter_selected_id")
        if let filterID, let preset = PhotoFilterCatalog.resolve(filterID) {
            let key = Np3FilterCatalog.preset(id: filterID)?.catalogKey ?? filterID
            let intensities = decodeAndroidIntensities(defaults.string(forKey: "photo_filter_intensities_v1"))
            value.selectedFilter = PhotoFilterSelection(preset: preset,
                intensityPercent: intensities[key] ?? (defaults.object(forKey: "photo_filter_intensity") as? Int ?? Np3FilterEngine.defaultIntensityPercent))
            value.filterIntensities = intensities
        }
        value.favoriteFilterIDs = Set(decodeAndroidFavorites(defaults.string(forKey: "favorite_photo_filters_v1")))
        let content = PhotoFrameWatermarkContent(rawValue: defaults.string(forKey: "photo_frame_watermark_content") ?? "TEXT") ?? .text
        value.watermark = PhotoFrameWatermark(
            enabled: defaults.object(forKey: "photo_frame_branding_enabled") as? Bool ?? true,
            content: content,
            text: defaults.string(forKey: "photo_frame_watermark_text") ?? PhotoFrameWatermark.defaultText,
            imageHash: defaults.string(forKey: "photo_frame_watermark_image_hash"),
            font: PhotoFrameWatermarkFont(rawValue: defaults.string(forKey: "photo_frame_watermark_font") ?? "CALLIGRAPHY") ?? .calligraphy,
            sizePercent: defaults.object(forKey: "photo_frame_watermark_size") as? Int ?? 80,
            position: PhotoFrameWatermarkPosition(rawValue: defaults.string(forKey: "photo_frame_watermark_position") ?? "AUTO") ?? .auto,
            color: PhotoFrameWatermarkColor(rawValue: defaults.string(forKey: "photo_frame_watermark_color") ?? "ADAPTIVE") ?? .adaptive,
            opacityPercent: defaults.object(forKey: "photo_frame_watermark_opacity") as? Int ?? 72,
            effect: PhotoFrameWatermarkEffect(rawValue: defaults.string(forKey: "photo_frame_watermark_effect") ?? "AUTO") ?? .auto)
        value.metadataByPreset = decodeAndroidMetadata(defaults.string(forKey: "photo_frame_metadata_settings_v1"))
        value.metadata = value.metadataByPreset[value.photoFramePreset.rawValue] ?? PhotoFrameMetadataSettings.defaults(for: value.photoFramePreset)
        value.favoriteFrameEffects = decodeAndroidFrameFavorites(defaults.string(forKey: "favorite_frame_effects_v1"), watermark: value.watermark)
        value.favoriteFramePresets = Set(value.favoriteFrameEffects.map(\.preset))
        return value
    }

    private static func persistAndroidTransferSettings(_ value: PhotoEffectsSettings, defaults: UserDefaults) {
        defaults.set(value.photoFrameEnabled, forKey: "photo_frame_enabled")
        defaults.set(value.photoFrameBorderEnabled, forKey: "photo_frame_border_enabled")
        defaults.set(value.photoFramePreset.rawValue, forKey: "photo_frame_preset")
        defaults.set(value.photoFilterEnabled && value.selectedFilter != nil, forKey: "photo_filter_enabled")
        if let selected = value.selectedFilter { defaults.set(selected.preset.id, forKey: "photo_filter_selected_id") }
        else { defaults.removeObject(forKey: "photo_filter_selected_id") }
        defaults.set(encodeAndroidIntensities(value.filterIntensities), forKey: "photo_filter_intensities_v1")
        defaults.set(encodeAndroidFavorites(value.favoriteFilterIDs), forKey: "favorite_photo_filters_v1")
        defaults.set(value.watermark.enabled, forKey: "photo_frame_branding_enabled")
        defaults.set(value.watermark.content.rawValue, forKey: "photo_frame_watermark_content")
        defaults.set(value.watermark.text, forKey: "photo_frame_watermark_text")
        if let hash = value.watermark.imageHash { defaults.set(hash, forKey: "photo_frame_watermark_image_hash") } else { defaults.removeObject(forKey: "photo_frame_watermark_image_hash") }
        defaults.set(value.watermark.font.rawValue, forKey: "photo_frame_watermark_font")
        defaults.set(value.watermark.sizePercent, forKey: "photo_frame_watermark_size")
        defaults.set(value.watermark.position.rawValue, forKey: "photo_frame_watermark_position")
        defaults.set(value.watermark.color.rawValue, forKey: "photo_frame_watermark_color")
        defaults.set(value.watermark.opacityPercent, forKey: "photo_frame_watermark_opacity")
        defaults.set(value.watermark.effect.rawValue, forKey: "photo_frame_watermark_effect")
        defaults.set(encodeAndroidMetadata(value.metadataByPreset), forKey: "photo_frame_metadata_settings_v1")
        defaults.set(encodeAndroidFrameFavorites(value.favoriteFrameEffects), forKey: "favorite_frame_effects_v1")
    }

    private static func decodeAndroidFavorites(_ raw: String?) -> [String] {
        raw?.split(separator: ";").map { String($0).split(separator: ",").first.map(String.init) ?? "" }.filter { !$0.isEmpty } ?? []
    }
    private static func encodeAndroidFavorites(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ";") }
    private static func decodeAndroidIntensities(_ raw: String?) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (raw ?? "").split(separator: ";").compactMap { entry in
            let f = entry.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 2, let n = Int(f[1]) else { return nil }
            return (String(f[0]), n)
        })
    }
    private static func encodeAndroidIntensities(_ values: [String: Int]) -> String {
        values.keys.sorted().compactMap { key in values[key].map { "\(key),\(min(max($0, 2), 100))" } }.joined(separator: ";")
    }
    private static func decodeAndroidFrameFavorites(_ raw: String?, watermark: PhotoFrameWatermark) -> [PhotoFrameFavorite] {
        (raw ?? "").split(separator: ";").compactMap { entry in
            let f = entry.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 9, let preset = PhotoFramePreset(rawValue: String(f[0])), let enabled = Bool(String(f[1])),
                  let content = PhotoFrameWatermarkContent(rawValue: String(f[2])), let font = PhotoFrameWatermarkFont(rawValue: String(f[3])),
                  let size = Int(f[4]), let position = PhotoFrameWatermarkPosition(rawValue: String(f[5])), let color = PhotoFrameWatermarkColor(rawValue: String(f[6])),
                  let opacity = Int(f[7]), let effect = PhotoFrameWatermarkEffect(rawValue: String(f[8])) else { return nil }
            return PhotoFrameFavorite(preset: preset, watermark: watermark.copy(enabled: enabled, content: content, font: font, sizePercent: size, position: position, color: color, opacityPercent: opacity, effect: effect))
        }
    }
    private static func encodeAndroidFrameFavorites(_ values: [PhotoFrameFavorite]) -> String {
        values.map { f in [f.preset.rawValue, String(f.watermark.enabled), f.watermark.content.rawValue, f.watermark.font.rawValue, String(f.watermark.sizePercent), f.watermark.position.rawValue, f.watermark.color.rawValue, String(f.watermark.opacityPercent), f.watermark.effect.rawValue].joined(separator: ",") }.joined(separator: ";")
    }
    private static func decodeAndroidMetadata(_ raw: String?) -> [String: PhotoFrameMetadataSettings] {
        var result: [String: PhotoFrameMetadataSettings] = [:]
        for entry in (raw ?? "").split(separator: ";") {
            let f = entry.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count == 12, let preset = PhotoFramePreset(rawValue: String(f[0])) else { continue }
            let bools = f[1...9].map { Bool(String($0)) }
            guard bools.allSatisfy({ $0 != nil }) else { continue }
            result[preset.rawValue] = PhotoFrameMetadataSettings(showDate: bools[0]!, showTime: bools[1]!, showFocalLength: bools[2]!, showExposure: bools[3]!, showBrand: bools[4]!, showModel: bools[5]!, showLensModel: bools[6]!, showCoordinates: bools[7]!, showAltitude: bools[8]!, datePattern: String(f[10]), timePattern: String(f[11]))
        }
        return result
    }
    private static func encodeAndroidMetadata(_ values: [String: PhotoFrameMetadataSettings]) -> String {
        values.keys.sorted().compactMap { key -> String? in
            guard let p = PhotoFramePreset(rawValue: key), let v = values[key] else { return nil }
            return [p.rawValue, String(v.showDate), String(v.showTime), String(v.showFocalLength), String(v.showExposure), String(v.showBrand), String(v.showModel), String(v.showLensModel), String(v.showCoordinates), String(v.showAltitude), v.datePattern, v.timePattern].joined(separator: "|")
        }.joined(separator: ";")
    }
}

private extension PhotoFrameWatermark {
    func copy(enabled: Bool, content: PhotoFrameWatermarkContent, font: PhotoFrameWatermarkFont, sizePercent: Int, position: PhotoFrameWatermarkPosition, color: PhotoFrameWatermarkColor, opacityPercent: Int, effect: PhotoFrameWatermarkEffect) -> PhotoFrameWatermark {
        var result = self
        result.enabled = enabled; result.content = content; result.font = font; result.sizePercent = sizePercent; result.position = position; result.color = color; result.opacityPercent = opacityPercent; result.effect = effect
        return result
    }
}
