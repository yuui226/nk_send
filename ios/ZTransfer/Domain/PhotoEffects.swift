import Foundation

enum PhotoEffectModule: Int, CaseIterable, Sendable {
    case filter = 1, lut = 2, frame = 4, watermark = 8
}

let allPhotoEffectModules = 15

func normalizePhotoEffectModules(_ mask: Int) -> Int {
    let value = mask & allPhotoEffectModules
    return value == 0 ? allPhotoEffectModules : value
}

func effectivePhotoEffectModules(_ mask: Int, isPro: Bool) -> Int {
    let normalized = normalizePhotoEffectModules(mask)
    return !isPro && (normalized & (PhotoEffectModule.frame.rawValue | PhotoEffectModule.watermark.rawValue)) != 0
        ? normalized | PhotoEffectModule.frame.rawValue | PhotoEffectModule.watermark.rawValue
        : normalized
}

/// Android togglePhotoEffectModule: free frame/watermark form one switch,
/// and a click may never remove the last available editor.
func togglePhotoEffectModule(_ mask: Int, module: PhotoEffectModule, isPro: Bool) -> Int {
    let current = effectivePhotoEffectModules(mask, isPro: isPro)
    let paired = PhotoEffectModule.frame.rawValue | PhotoEffectModule.watermark.rawValue
    let bits = !isPro && (module == .frame || module == .watermark) ? paired : module.rawValue
    let next = current ^ bits
    return next == 0 ? current : next
}

/// Shared editor command: keep the draft and its role-owned LUT persistence
/// in the same synchronous transition. A rejected last-module click is a no-op.
@MainActor
@discardableResult
func togglePhotoEffectModuleDraft(_ module: PhotoEffectModule,
                                  draft: inout PhotoEffectsSettings,
                                  lutStore: PhotoLUTStore, isPro: Bool) -> Bool {
    let current = effectivePhotoEffectModules(draft.photoEffectModules, isPro: isPro)
    let next = togglePhotoEffectModule(current, module: module, isPro: isPro)
    guard next != current else { return false }
    draft.applyModuleVisibility(next, isPro: isPro)
    if !photoEffectModuleIsVisible(next, .lut) { lutStore.select(nil) }
    return true
}

/// Android PhotoLutEditorState.off clears the active LUT and source selection.
/// Retained NP3 preferences are unrelated to turning off the LUT editor.
@MainActor
func disablePhotoLUTDraft(_ draft: inout PhotoEffectsSettings, lutStore: PhotoLUTStore) {
    if draft.colorEffectModule == .lut {
        draft.photoFilterEnabled = false
        draft.selectedFilter = nil
    }
    lutStore.select(nil)
}

func photoEffectModuleIsVisible(_ mask: Int, _ module: PhotoEffectModule) -> Bool {
    mask & module.rawValue != 0
}
import CoreFoundation
import Combine
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

private final class PhotoEffectsWatermarkImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: UIImage] = [:]
    private var insertionOrder: [String] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func image(for hash: String, load: () -> UIImage?) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let image = images[hash] { return image }
        guard let image = load() else { return nil }
        images[hash] = image
        insertionOrder.append(hash)
        while insertionOrder.count > capacity {
            images.removeValue(forKey: insertionOrder.removeFirst())
        }
        return image
    }

    func removeAll() {
        lock.lock()
        images.removeAll()
        insertionOrder.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }
}

/// Persisted names and defaults mirror PhotoFrameExporter.kt.  The renderer and
/// settings UI both consume these values so a draft can never silently change a
/// queued task's output.
enum PhotoFramePreset: String, CaseIterable, Codable, Sendable {
    case mist = "MIST", cinema = "CINEMA", minimal = "MINIMAL", frosted = "FROSTED"
    case plaque = "PLAQUE", immersive = "IMMERSIVE", brandInset = "BRAND_INSET", brandGallery = "BRAND_GALLERY"
    case classicSignature = "CLASSIC_SIGNATURE", galleryMat = "GALLERY_MAT", colorArchive = "COLOR_ARCHIVE"
    case filmGallery = "FILM_GALLERY", filmEdge = "FILM_EDGE"
    case filmNegative = "FILM_NEGATIVE", parameterPoster = "PARAMETER_POSTER"
}

extension PhotoFramePreset {
    var supportsWidthControl: Bool { self != .immersive }
    var supportsBackdropControls: Bool {
        switch self {
        case .mist, .frosted, .cinema, .filmGallery, .parameterPoster: return true
        default: return false
        }
    }
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
    static let sizeRange = 1...300
    static let opacityRange = 1...100
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
        let trimmed = limitedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultText : trimmed
    }

    static func limitText(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(
            of: "[\\r\\n\\t]+",
            with: " ",
            options: .regularExpression
        )
        let scalars = singleLine.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(scalars.prefix(Self.maxTextLength)))
    }

    /// Android replaces line breaks/tabs with one space, removes remaining
    /// control scalars, then truncates by Unicode code point.
    var limitedText: String {
        Self.limitText(text)
    }
}

/// Android migrated the former visual-size scale by subtracting 49 from the
/// stored percentage. Named legacy stops first resolve to their old numeric
/// anchors, then use the same conversion.
func restoredPhotoFrameWatermarkSizePercent(
    _ persisted: Any?, content: PhotoFrameWatermarkContent, usesLegacyScale: Bool = false
) -> Int {
    guard let persisted else { return 80 }
    let named: Bool
    let raw: Int
    if let number = persisted as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        raw = 80
        named = false
    } else if let number = persisted as? NSNumber {
        raw = number.intValue
        named = false
    } else if let text = persisted as? String {
        if let value = Int(text) {
            raw = value
            named = false
        } else {
            named = true
            switch text {
            case "SMALL": raw = content == .image ? 47 : 58
            case "MEDIUM": raw = content == .image ? 69 : 75
            case "LARGE": raw = 100
            default: raw = 75
            }
        }
    } else {
        raw = 80
        named = false
    }
    let converted = usesLegacyScale || named ? raw - 49 : raw
    return min(max(converted, PhotoFrameWatermark.sizeRange.lowerBound),
               PhotoFrameWatermark.sizeRange.upperBound)
}

func restoredPhotoFrameWatermarkOpacityPercent(_ persisted: Any?) -> Int {
    let raw: Int
    if let number = persisted as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        raw = 72
    } else if let number = persisted as? NSNumber {
        raw = number.intValue
    } else if let text = persisted as? String {
        raw = Int(text) ?? {
            switch text {
            case "SUBTLE": return 40
            case "STANDARD": return 72
            case "STRONG": return 100
            default: return 72
            }
        }()
    } else {
        raw = 72
    }
    return min(max(raw, PhotoFrameWatermark.opacityRange.lowerBound),
               PhotoFrameWatermark.opacityRange.upperBound)
}

/// Android favorites retain presentation settings, never historical text or
/// image identity. The legacy Codable shape is retained for existing installs.
struct PhotoFrameFavorite: Codable, Equatable, Sendable {
    var preset: PhotoFramePreset
    var watermark: PhotoFrameWatermark
    var frameWidthPercent: Int
    var backgroundBlurPercent: Int
    var backgroundMaskPercent: Int

    init(preset: PhotoFramePreset, watermark: PhotoFrameWatermark,
         frameWidthPercent: Int = 100, backgroundBlurPercent: Int = 100,
         backgroundMaskPercent: Int = 100) {
        self.preset = preset
        self.watermark = watermark
        self.frameWidthPercent = normalizePhotoFrameWidthPercent(frameWidthPercent)
        self.backgroundBlurPercent = normalizePhotoFrameBackdropPercent(backgroundBlurPercent)
        self.backgroundMaskPercent = normalizePhotoFrameBackdropPercent(backgroundMaskPercent)
    }

    init(preset: PhotoFramePreset, watermark: PhotoFrameWatermark,
         metadata: PhotoFrameMetadataSettings) {
        self.init(preset: preset, watermark: watermark, frameWidthPercent: metadata.widthPercent,
                  backgroundBlurPercent: metadata.backgroundBlurPercent,
                  backgroundMaskPercent: metadata.backgroundMaskPercent)
    }

    mutating func updateFrameMetadata(_ metadata: PhotoFrameMetadataSettings) {
        frameWidthPercent = normalizePhotoFrameWidthPercent(metadata.widthPercent)
        backgroundBlurPercent = normalizePhotoFrameBackdropPercent(metadata.backgroundBlurPercent)
        backgroundMaskPercent = normalizePhotoFrameBackdropPercent(metadata.backgroundMaskPercent)
    }

    func applying(to metadata: PhotoFrameMetadataSettings) -> PhotoFrameMetadataSettings {
        var result = metadata
        result.widthPercent = normalizePhotoFrameWidthPercent(frameWidthPercent)
        result.backgroundBlurPercent = normalizePhotoFrameBackdropPercent(backgroundBlurPercent)
        result.backgroundMaskPercent = normalizePhotoFrameBackdropPercent(backgroundMaskPercent)
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case preset, watermark, frameWidthPercent, backgroundBlurPercent, backgroundMaskPercent
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try values.decode(PhotoFramePreset.self, forKey: .preset),
                  watermark: try values.decode(PhotoFrameWatermark.self, forKey: .watermark),
                  frameWidthPercent: try values.decodeIfPresent(Int.self, forKey: .frameWidthPercent) ?? 100,
                  backgroundBlurPercent: try values.decodeIfPresent(Int.self, forKey: .backgroundBlurPercent) ?? 100,
                  backgroundMaskPercent: try values.decodeIfPresent(Int.self, forKey: .backgroundMaskPercent) ?? 100)
    }

    func applying(to current: PhotoFrameWatermark) -> PhotoFrameWatermark? {
        if watermark.content == .image {
            guard let hash = current.imageHash,
                  hash.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return nil }
        }
        var result = watermark
        result.text = current.text
        result.imageHash = current.imageHash
        result.sizePercent = min(max(result.sizePercent, PhotoFrameWatermark.sizeRange.lowerBound), PhotoFrameWatermark.sizeRange.upperBound)
        result.opacityPercent = min(max(result.opacityPercent, PhotoFrameWatermark.opacityRange.lowerBound), PhotoFrameWatermark.opacityRange.upperBound)
        return result
    }
}

enum PhotoFrameBrandStyle: String, Codable, CaseIterable, Sendable { case text, logo }
func normalizePhotoFrameWidthPercent(_ value: Int) -> Int { min(max(value, 60), 200).rounded(toMultipleOf: 5) }
func normalizePhotoFrameBackdropPercent(_ value: Int) -> Int { min(max(value, 0), 200).rounded(toMultipleOf: 10) }
func photoFrameBackdropMaskAlpha(_ alpha: Int, percent: Int) -> Int {
    min(255, max(0, Int((Double(alpha) * Double(min(200, max(0, percent))) / 100).rounded())))
}

func photoFrameBackdropPreviewLongEdge(_ preset: PhotoFramePreset, blurPercent: Int) -> Int {
    guard preset.supportsBackdropControls else { return 192 }
    let blur = normalizePhotoFrameBackdropPercent(blurPercent)
    return blur == 0 ? 1024 : blur < 50 ? 384 : 192
}

private extension Int { func rounded(toMultipleOf step: Int) -> Int { ((self + step / 2) / step) * step } }

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
    var showAddress = false
    var showCity = false
    var showRegion = false
    var brandStyle: PhotoFrameBrandStyle = .text
    var widthPercent = 100
    var backgroundBlurPercent = 100
    var backgroundMaskPercent = 100
    var datePattern = "yyyy-MM-dd"
    var timePattern = "HH:mm:ss"

    private enum CodingKeys: String, CodingKey { case showDate, showTime, showFocalLength, showExposure, showBrand, showModel, showLensModel, showCoordinates, showAltitude, showAddress, showCity, showRegion, brandStyle, widthPercent, backgroundBlurPercent, backgroundMaskPercent, datePattern, timePattern }
    init() {}
    init(showCoordinates: Bool) { self.init(); self.showCoordinates = showCoordinates }
    init(showDate: Bool, showTime: Bool, showCoordinates: Bool, showAltitude: Bool) { self.init(); self.showDate = showDate; self.showTime = showTime; self.showCoordinates = showCoordinates; self.showAltitude = showAltitude }
    init(showCoordinates: Bool, showAltitude: Bool, datePattern: String, timePattern: String) { self.init(); self.showCoordinates = showCoordinates; self.showAltitude = showAltitude; self.datePattern = datePattern; self.timePattern = timePattern }
    init(showDate: Bool, showTime: Bool, showFocalLength: Bool, showExposure: Bool, showBrand: Bool, showModel: Bool, showLensModel: Bool, showCoordinates: Bool, showAltitude: Bool, datePattern: String, timePattern: String, brandStyle: PhotoFrameBrandStyle = .text, showAddress: Bool = false, showCity: Bool = false, showRegion: Bool = false, widthPercent: Int = 100, backgroundBlurPercent: Int = 100, backgroundMaskPercent: Int = 100) {
        self.showDate = showDate; self.showTime = showTime; self.showFocalLength = showFocalLength; self.showExposure = showExposure
        self.showBrand = showBrand; self.showModel = showModel; self.showLensModel = showLensModel; self.showCoordinates = showCoordinates; self.showAltitude = showAltitude
        self.showAddress = showAddress; self.showCity = showCity; self.showRegion = showRegion; self.brandStyle = brandStyle
        self.widthPercent = widthPercent; self.backgroundBlurPercent = backgroundBlurPercent; self.backgroundMaskPercent = backgroundMaskPercent
        self.datePattern = datePattern; self.timePattern = timePattern
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showDate = try c.decodeIfPresent(Bool.self, forKey: .showDate) ?? true
        showTime = try c.decodeIfPresent(Bool.self, forKey: .showTime) ?? true
        showFocalLength = try c.decodeIfPresent(Bool.self, forKey: .showFocalLength) ?? true
        showExposure = try c.decodeIfPresent(Bool.self, forKey: .showExposure) ?? true
        showBrand = try c.decodeIfPresent(Bool.self, forKey: .showBrand) ?? true
        showModel = try c.decodeIfPresent(Bool.self, forKey: .showModel) ?? true
        showLensModel = try c.decodeIfPresent(Bool.self, forKey: .showLensModel) ?? false
        showCoordinates = try c.decodeIfPresent(Bool.self, forKey: .showCoordinates) ?? false
        showAltitude = try c.decodeIfPresent(Bool.self, forKey: .showAltitude) ?? false
        showAddress = try c.decodeIfPresent(Bool.self, forKey: .showAddress) ?? false
        showCity = try c.decodeIfPresent(Bool.self, forKey: .showCity) ?? false
        showRegion = try c.decodeIfPresent(Bool.self, forKey: .showRegion) ?? false
        brandStyle = try c.decodeIfPresent(PhotoFrameBrandStyle.self, forKey: .brandStyle) ?? .text
        widthPercent = normalizePhotoFrameWidthPercent(try c.decodeIfPresent(Int.self, forKey: .widthPercent) ?? 100)
        backgroundBlurPercent = normalizePhotoFrameBackdropPercent(try c.decodeIfPresent(Int.self, forKey: .backgroundBlurPercent) ?? 100)
        backgroundMaskPercent = normalizePhotoFrameBackdropPercent(try c.decodeIfPresent(Int.self, forKey: .backgroundMaskPercent) ?? 100)
        datePattern = try c.decodeIfPresent(String.self, forKey: .datePattern) ?? "yyyy-MM-dd"
        timePattern = try c.decodeIfPresent(String.self, forKey: .timePattern) ?? "HH:mm:ss"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showDate, forKey: .showDate); try c.encode(showTime, forKey: .showTime)
        try c.encode(showFocalLength, forKey: .showFocalLength); try c.encode(showExposure, forKey: .showExposure)
        try c.encode(showBrand, forKey: .showBrand); try c.encode(showModel, forKey: .showModel)
        try c.encode(showLensModel, forKey: .showLensModel); try c.encode(showCoordinates, forKey: .showCoordinates)
        try c.encode(showAltitude, forKey: .showAltitude); try c.encode(brandStyle, forKey: .brandStyle)
        try c.encode(showAddress, forKey: .showAddress); try c.encode(showCity, forKey: .showCity); try c.encode(showRegion, forKey: .showRegion)
        try c.encode(widthPercent, forKey: .widthPercent); try c.encode(backgroundBlurPercent, forKey: .backgroundBlurPercent); try c.encode(backgroundMaskPercent, forKey: .backgroundMaskPercent)
        try c.encode(datePattern, forKey: .datePattern); try c.encode(timePattern, forKey: .timePattern)
    }

    static func defaults(for preset: PhotoFramePreset) -> Self {
        var value = Self()
        switch preset {
        case .classicSignature:
            value.showDate = false; value.showTime = false; value.showModel = false
        case .galleryMat, .filmEdge:
            value.showDate = false; value.showTime = false; value.showFocalLength = false; value.showExposure = false; value.showBrand = false; value.showModel = false
        case .filmNegative:
            value.showDate = true; value.showTime = false; value.showFocalLength = true; value.showExposure = true
            value.showBrand = true; value.showModel = true; value.showLensModel = false
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

/// Android chooser category order and initial scroll use the same visible list.
struct PhotoFilterChooserState {
    var isPresented = false
    var category: PhotoEffectFilterCategory = .all

    func items(in settings: PhotoEffectsSettings) -> [PhotoFilterPreset] {
        settings.orderedFilters.filter { preset in
            switch category {
            case .all: return true
            case .favorites: return settings.favoriteFilterIDs.contains(PhotoEffectsSettings.filterKey(preset.id))
            default: return preset.category == category
            }
        }
    }

    func initialItemID(in settings: PhotoEffectsSettings) -> String? {
        let visible = items(in: settings)
        if settings.photoFilterEnabled,
           let selected = settings.selectedFilter?.preset.id,
           visible.contains(where: { $0.id == selected }) { return selected }
        return visible.first?.id
    }

    mutating func select(_ id: String?, in settings: inout PhotoEffectsSettings) {
        settings.selectFilter(id)
        isPresented = false
    }
}

enum PhotoEffectFilterCategory: String, CaseIterable, Identifiable, Sendable {
    case all, favorites, landscape, portrait, monochrome, film, cinematic, color
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"; case .favorites: return "收藏"; case .landscape: return "风景"; case .portrait: return "人像"
        case .monochrome: return "黑白"; case .film: return "胶片"; case .cinematic: return "电影感"; case .color: return "色彩"
        }
    }
}

extension PhotoFilterPreset {
    var category: PhotoEffectFilterCategory {
        // Android BuiltInPhotoFilters uses fallbackName as category metadata.
        let value = Np3FilterCatalog.preset(id: id)?.fallbackName ?? name
        if value.range(of: "黑白|单色|Mono", options: [.regularExpression, .caseInsensitive]) != nil { return .monochrome }
        if value.range(of: "人像|Portrait|Skin|Love Glow|Warm Portrait|Soft Portrait", options: [.regularExpression, .caseInsensitive]) != nil { return .portrait }
        if value.range(of: "风景|Landscape|Nature|Forest|Fern|Moss|Urban Green|Blue Hour|Sunset", options: [.regularExpression, .caseInsensitive]) != nil { return .landscape }
        if value.range(of: "电影|Cine|Cinema|Teal and Orange|Dusk", options: [.regularExpression, .caseInsensitive]) != nil { return .cinematic }
        if value.range(of: "胶片|Film|Vintage|Darkroom", options: [.regularExpression, .caseInsensitive]) != nil { return .film }
        return .color
    }
}


struct PhotoFilterPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct LUTAdjustments: Codable, Equatable, Sendable {
    var contrast = 0
    var saturation = 0
    var highlights = 0
    var shadows = 0

    var normalized: Self {
        Self(contrast: min(max(contrast, -100), 100), saturation: min(max(saturation, -100), 100),
             highlights: min(max(highlights, -100), 100), shadows: min(max(shadows, -100), 100))
    }
    var isNeutral: Bool { contrast == 0 && saturation == 0 && highlights == 0 && shadows == 0 }
}

struct PhotoFilterSelection: Codable, Equatable, Sendable {
    let preset: PhotoFilterPreset
    var intensityPercent: Int
    var lutAdjustments: LUTAdjustments
    let snapshotOwner: PhotoLUTSnapshotOwner?
    var normalizedIntensityPercent: Int { Np3FilterEngine.normalizeIntensity(intensityPercent) }

    init(preset: PhotoFilterPreset, intensityPercent: Int, lutAdjustments: LUTAdjustments = .init()) {
        self.preset = preset
        self.intensityPercent = intensityPercent
        self.lutAdjustments = lutAdjustments.normalized
        snapshotOwner = preset.id.hasPrefix("cube:")
            ? PhotoLUTRuntime.snapshotOwner(digest: String(preset.id.dropFirst(5))) : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.preset == rhs.preset && lhs.intensityPercent == rhs.intensityPercent
            && lhs.lutAdjustments == rhs.lutAdjustments
    }

    private enum CodingKeys: String, CodingKey { case preset, intensityPercent, lutAdjustments }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try values.decode(PhotoFilterPreset.self, forKey: .preset),
                  intensityPercent: try values.decode(Int.self, forKey: .intensityPercent),
                  lutAdjustments: try values.decodeIfPresent(LUTAdjustments.self, forKey: .lutAdjustments) ?? .init())
    }
}

/// Metadata, identity and ordering come from Android's curated NP3 catalog.
enum PhotoFilterCatalog {
    static let presets = Np3FilterCatalog.presets.map { PhotoFilterPreset(id: $0.id, name: $0.name) }

    static func resolve(_ id: String) -> PhotoFilterPreset? {
        Np3FilterCatalog.preset(id: id).map { PhotoFilterPreset(id: $0.id, name: $0.name) }
    }
}

extension PhotoFrameMetadataSettings {
    /// Android nextBrandStyle: disabling always resets the remembered style to text.
    mutating func cycleBrandStyle() {
        if !showBrand { showBrand = true; brandStyle = .text }
        else if brandStyle == .text { brandStyle = .logo }
        else { showBrand = false; brandStyle = .text }
    }

    var brandControlLabelKey: String {
        guard showBrand else { return "photo_frame_metadata_brand" }
        return brandStyle == .logo ? "photo_frame_metadata_brand_logo" : "photo_frame_metadata_brand_text"
    }
}

struct PhotoEffectsSettings: Codable, Equatable, Sendable {
    var photoFrameEnabled = false
    var photoFrameBorderEnabled = true
    /// Android stores editor visibility separately from whether an effect is enabled.
    var photoEffectModules = allPhotoEffectModules
    var photoFramePreset: PhotoFramePreset = .mist
    var watermark = PhotoFrameWatermark()
    var metadata = PhotoFrameMetadataSettings.defaults(for: .mist)
    /// Android keeps metadata overrides per frame preset. The legacy `metadata`
    /// value remains as the migration/default value for older iOS preferences.
    var metadataByPreset: [String: PhotoFrameMetadataSettings] = [:]
    var photoFilterEnabled = false
    var selectedFilter: PhotoFilterSelection?
    var filterIntensities: [String: Int] = [:]
    /// Android orderWithFavorites preserves the order in which favorites were
    /// added. A Set silently changes the wheel and category chooser ordering.
    var favoriteFilterIDs: [String] = []
    var favoriteFramePresets: Set<PhotoFramePreset> = []
    var favoriteFrameEffects: [PhotoFrameFavorite] = []

    var colorEffectModule: PhotoEffectModule {
        selectedFilter?.preset.id.hasPrefix("cube:") == true ? .lut : .filter
    }

    var hasEffect: Bool {
        photoFrameEnabled || (photoFilterEnabled && selectedFilter != nil)
    }

    init() {}

    static func filterKey(_ id: String) -> String {
        Np3FilterCatalog.preset(id: id)?.catalogKey ?? id
    }

    var orderedFilters: [PhotoFilterPreset] {
        let presets = PhotoFilterCatalog.presets
        let byKey = Dictionary(uniqueKeysWithValues: presets.map { (Self.filterKey($0.id), $0) })
        var seen = Set<String>()
        let favorites = favoriteFilterIDs.filter { seen.insert($0).inserted }.compactMap { byKey[$0] }
        return favorites + presets.filter { !favoriteFilterIDs.contains(Self.filterKey($0.id)) }
    }

    var orderedFramePresets: [PhotoFramePreset] {
        var seen = Set<PhotoFramePreset>()
        let favorites = favoriteFrameEffects.map(\.preset)
            .filter { seen.insert($0).inserted }
        return favorites + PhotoFramePreset.allCases.filter { seen.insert($0).inserted }
    }

    mutating func selectFilter(_ id: String?) {
        guard let id else {
            photoFilterEnabled = false
            return
        }
        let preset: PhotoFilterPreset
        if id.hasPrefix("cube:") {
            guard PhotoLUTRuntime.contains(digest: String(id.dropFirst(5))) else { photoFilterEnabled = false; return }
            preset = PhotoFilterPreset(id: id, name: "LUT \(id.dropFirst(5).prefix(8))")
        } else if let resolved = PhotoFilterCatalog.resolve(id) {
            preset = resolved
        } else { photoFilterEnabled = false; return }
        let key = Self.filterKey(id)
        let intensity = filterIntensities[key] ?? Np3FilterEngine.defaultIntensityPercent
        selectedFilter = .init(preset: preset, intensityPercent: intensity)
        photoFilterEnabled = true
        filterIntensities[key] = intensity
    }

    mutating func toggleFilterFavorite(_ id: String) {
        let key = Self.filterKey(id)
        if favoriteFilterIDs.contains(key) { favoriteFilterIDs.removeAll { $0 == key } }
        else { favoriteFilterIDs.append(key) }
    }

    /// Explicit module visibility changes turn effects off without discarding
    /// their parameters. Merely rendering with reduced access does not call this.
    mutating func applyModuleVisibility(_ mask: Int, isPro: Bool = true) {
        photoEffectModules = effectivePhotoEffectModules(mask, isPro: isPro)
        if !photoEffectModuleIsVisible(photoEffectModules, colorEffectModule) { photoFilterEnabled = false }
        if !photoEffectModuleIsVisible(photoEffectModules, .frame) { photoFrameBorderEnabled = false }
        if !photoEffectModuleIsVisible(photoEffectModules, .watermark) { watermark.enabled = false }
        photoFrameEnabled = photoFrameEnabled && (photoFrameBorderEnabled || (isPro && watermark.enabled))
    }

    /// SettingsScreen persists these editor preferences immediately while the
    /// selected filter/frame/watermark remain a draft until returning/closing.
    func persistingEditorPreferences(from draft: Self) -> Self {
        var result = self
        result.filterIntensities = draft.filterIntensities
        result.favoriteFilterIDs = draft.favoriteFilterIDs
        result.favoriteFrameEffects = draft.favoriteFrameEffects
        result.favoriteFramePresets = draft.favoriteFramePresets
        result.applyModuleVisibility(draft.photoEffectModules)
        result.metadataByPreset = draft.metadataByPreset
        result.metadata = result.metadataByPreset[result.photoFramePreset.rawValue]
            ?? PhotoFrameMetadataSettings.defaults(for: result.photoFramePreset)
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case photoFrameEnabled, photoFrameBorderEnabled, photoEffectModules, photoFramePreset, watermark,
             metadata, metadataByPreset, photoFilterEnabled, selectedFilter, filterIntensities, favoriteFilterIDs,
             favoriteFramePresets, favoriteFrameEffects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photoFrameEnabled = try c.decodeIfPresent(Bool.self, forKey: .photoFrameEnabled) ?? false
        photoFrameBorderEnabled = try c.decodeIfPresent(Bool.self, forKey: .photoFrameBorderEnabled) ?? true
        photoEffectModules = normalizePhotoEffectModules(try c.decodeIfPresent(Int.self, forKey: .photoEffectModules) ?? allPhotoEffectModules)
        photoFramePreset = try c.decodeIfPresent(PhotoFramePreset.self, forKey: .photoFramePreset) ?? .mist
        watermark = try c.decodeIfPresent(PhotoFrameWatermark.self, forKey: .watermark) ?? PhotoFrameWatermark()
        metadata = try c.decodeIfPresent(PhotoFrameMetadataSettings.self, forKey: .metadata) ?? PhotoFrameMetadataSettings()
        metadataByPreset = try c.decodeIfPresent([String: PhotoFrameMetadataSettings].self, forKey: .metadataByPreset) ?? [:]
        photoFilterEnabled = try c.decodeIfPresent(Bool.self, forKey: .photoFilterEnabled) ?? false
        selectedFilter = try c.decodeIfPresent(PhotoFilterSelection.self, forKey: .selectedFilter)
        filterIntensities = try c.decodeIfPresent([String: Int].self, forKey: .filterIntensities) ?? [:]
        favoriteFilterIDs = try c.decodeIfPresent([String].self, forKey: .favoriteFilterIDs) ?? []
        favoriteFramePresets = try c.decodeIfPresent(Set<PhotoFramePreset>.self, forKey: .favoriteFramePresets) ?? []
        favoriteFrameEffects = try c.decodeIfPresent([PhotoFrameFavorite].self, forKey: .favoriteFrameEffects) ?? []
    }
}

/// Pixel identity used by both interactive preview entries. Android passes
/// only the active filter/frame/watermark arguments to its renderer; editor
/// preferences such as favorites and inactive presets must not restart the
/// current preview or replay its frame transition.
func nextPhotoFilterSelections(for settings: PhotoEffectsSettings) -> [PhotoFilterSelection] {
    guard settings.photoFilterEnabled, let selected = settings.selectedFilter else { return [] }
    let ordered = settings.orderedFilters
    guard let index = ordered.firstIndex(where: { $0.id == selected.preset.id }),
          index < ordered.index(before: ordered.endIndex) else { return [] }
    return ordered.dropFirst(index + 1).prefix(2).map { preset in
        let key = PhotoEffectsSettings.filterKey(preset.id)
        return PhotoFilterSelection(
            preset: preset,
            intensityPercent: settings.filterIntensities[key] ?? 80,
        )
    }
}

func photoEffectsPreviewPixelSettings(_ settings: PhotoEffectsSettings) -> PhotoEffectsSettings {
    var result = settings
    result.filterIntensities = [:]
    result.favoriteFilterIDs = []
    result.favoriteFramePresets = []
    result.favoriteFrameEffects = []
    result.metadataByPreset = [:]
    if !result.photoFilterEnabled { result.selectedFilter = nil }
    if !result.photoFrameEnabled {
        result.photoFrameBorderEnabled = false
        result.photoFramePreset = .mist
        result.watermark = PhotoFrameWatermark(enabled: false)
        result.metadata = .defaults(for: .mist)
    } else if !result.photoFrameBorderEnabled {
        result.photoFramePreset = .mist
        result.metadata = .defaults(for: .mist)
        if !result.watermark.enabled { result.watermark = PhotoFrameWatermark(enabled: false) }
    } else if !result.watermark.enabled {
        result.watermark = PhotoFrameWatermark(enabled: false)
    }
    // Android requestedRenderWatermark uses displayText. Whitespace-equivalent
    // text edits render identical pixels and must not restart preview work.
    if result.watermark.content == .text { result.watermark.text = result.watermark.displayText }
    return result
}

// MARK: Android-compatible rendered-output identity

/// Returns the exact derived-image filename used by PhotoFrameExporter.kt.
/// The identity deliberately contains only rendering inputs and version
/// tokens, never the full Codable description of a Swift value.
func androidPhotoFrameOutputName(sourceName: String, settings: PhotoEffectsSettings) -> String {
    let preset = settings.photoFramePreset
    let borderEnabled = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
    // Android's queue snapshot only carries a watermark when the decoration
    // feature is enabled. The persisted watermark preference defaults to on,
    // but it must not turn a filter-only export into a watermark render.
    let watermarkPreference = settings.photoFrameEnabled
        ? settings.watermark
        : PhotoFrameWatermark(enabled: false)
    let renderedWatermark = androidWatermarkForBorderMode(watermarkPreference, borderEnabled: borderEnabled)
    let metadata = borderEnabled
        ? (settings.metadataByPreset[preset.rawValue]
            ?? PhotoFrameMetadataSettings.defaults(for: preset))
        : PhotoFrameMetadataSettings.defaults(for: preset)
    let filter = settings.photoFilterEnabled ? settings.selectedFilter : nil
    let watermarkSuffix: String
    if borderEnabled || renderedWatermark.enabled {
        watermarkSuffix = "_w\(androidWatermarkFingerprint(renderedWatermark, preset: preset, metadata: metadata))"
    } else {
        watermarkSuffix = ""
    }
    let filterSuffix = filter.map {
        "_f\(androidFilterFingerprint($0))i\($0.normalizedIntensityPercent)"
    } ?? ""
    let style: String
    if borderEnabled {
        style = "frame_\(androidFramePresetSuffix(preset))"
    } else if renderedWatermark.enabled {
        style = "watermark"
    } else if filter != nil {
        style = "filter"
    } else {
        style = "watermark"
    }
    let stem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
    return "\(stem)_\(style)\(watermarkSuffix)\(filterSuffix).jpg"
}

/// TransferViewModel.kt effectivePhotoFrameWatermark. The caller captures this
/// value at enqueue, and previews use the same policy without writing it back
/// to the user's saved preferences. Renderers never read the live entitlement.
func effectivePhotoFrameWatermark(isPro: Bool, preference: PhotoFrameWatermark,
                                 borderEnabled: Bool = true) -> PhotoFrameWatermark {
    var value = isPro ? preference : PhotoFrameWatermark(opacityPercent: 80)
    let hash = value.imageHash?.lowercased()
    let validHash = hash.flatMap { candidate -> String? in
        candidate.count == 64 && candidate.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        } ? candidate : nil
    }
    value.imageHash = validHash
    if value.content == .image, validHash == nil { value.content = .text }
    value.text = value.displayText
    value.sizePercent = min(max(value.sizePercent, PhotoFrameWatermark.sizeRange.lowerBound),
                            PhotoFrameWatermark.sizeRange.upperBound)
    value.opacityPercent = min(max(value.opacityPercent, PhotoFrameWatermark.opacityRange.lowerBound),
                               PhotoFrameWatermark.opacityRange.upperBound)
    return androidWatermarkForBorderMode(value, borderEnabled: borderEnabled)
}

/// Android PhotoColorEffectGroup: remembered but disabled selections do not
/// hide the other editor. Module availability remains an independent gate.
struct PhotoColorEffectEditorVisibility: Equatable {
    let filter: Bool
    let lut: Bool

    init(settings: PhotoEffectsSettings, isPro: Bool) {
        let modules = effectivePhotoEffectModules(settings.photoEffectModules, isPro: isPro)
        let activeCube = settings.photoFilterEnabled && settings.colorEffectModule == .lut
        let activeFilter = settings.photoFilterEnabled &&
            settings.selectedFilter.flatMap { PhotoFilterCatalog.resolve($0.preset.id) } != nil
        filter = photoEffectModuleIsVisible(modules, .filter) && !activeCube
        lut = photoEffectModuleIsVisible(modules, .lut) && !activeFilter
    }
}

func effectivePhotoEffectsSettings(_ preference: PhotoEffectsSettings, isPro: Bool) -> PhotoEffectsSettings {
    var value = preference
    let modules = effectivePhotoEffectModules(preference.photoEffectModules, isPro: isPro)
    value.photoEffectModules = modules
    value.photoFilterEnabled = preference.photoFilterEnabled && photoEffectModuleIsVisible(modules, preference.colorEffectModule)
    value.photoFrameBorderEnabled = preference.photoFrameBorderEnabled && photoEffectModuleIsVisible(modules, .frame)
    value.watermark = preference.photoFrameEnabled
        ? effectivePhotoFrameWatermark(isPro: isPro, preference: preference.watermark,
                                       borderEnabled: value.photoFrameBorderEnabled && photoEffectModuleIsVisible(modules, .watermark))
        : PhotoFrameWatermark(enabled: false)
    if !photoEffectModuleIsVisible(modules, .watermark) { value.watermark.enabled = false }
    value.photoFrameEnabled = preference.photoFrameEnabled &&
        (value.photoFrameBorderEnabled || value.watermark.enabled)
    return value
}

private func androidWatermarkForBorderMode(_ watermark: PhotoFrameWatermark, borderEnabled: Bool) -> PhotoFrameWatermark {
    guard (!borderEnabled || watermark.content == .image),
          !androidPhotoPlacement(watermark.position) else { return watermark }
    var result = watermark
    result.position = .photoBottomCenter
    return result
}

private func androidPhotoPlacement(_ position: PhotoFrameWatermarkPosition) -> Bool {
    switch position {
    case .photoTopLeft, .photoTopCenter, .photoTopRight,
         .photoCenter, .photoBottomLeft, .photoBottomCenter, .photoBottomRight:
        return true
    default:
        return false
    }
}

private func androidFramePresetSuffix(_ preset: PhotoFramePreset) -> String {
    switch preset {
    case .mist: return "mist"
    case .cinema: return "dark"
    case .minimal: return "clean"
    case .frosted: return "glass"
    case .plaque: return "plaque"
    case .immersive: return "immersive"
    case .brandInset: return "brand_inset"
    case .brandGallery: return "brand_gallery"
    case .classicSignature: return "classic_signature"
    case .galleryMat: return "gallery_mat"
    case .colorArchive: return "color_archive"
    case .filmGallery: return "film_gallery"
    case .filmEdge: return "film_edge"
    case .filmNegative: return "film_negative"
    case .parameterPoster: return "parameter_poster"
    }
}

private func androidIsBrandFrame(_ preset: PhotoFramePreset) -> Bool {
    preset == .brandInset || preset == .brandGallery
}

private func androidIsEditorialFrame(_ preset: PhotoFramePreset) -> Bool {
    switch preset {
    case .classicSignature, .galleryMat, .colorArchive, .filmGallery, .filmEdge, .filmNegative, .parameterPoster: return true
    default: return false
    }
}

private func androidResolvedWatermarkPosition(_ preset: PhotoFramePreset, _ requested: PhotoFrameWatermarkPosition) -> PhotoFrameWatermarkPosition {
    guard requested == .auto else { return requested }
    switch preset {
    case .plaque: return .left
    case .immersive: return .auto
    case .brandInset, .brandGallery, .classicSignature, .colorArchive, .filmEdge: return .photoBottomRight
    case .filmNegative, .parameterPoster: return .center
    case .galleryMat, .filmGallery: return .center
    default: return .center
    }
}

private func androidNormalizedWatermarkSize(_ value: Int) -> Int { min(max(value, 1), 300) }
private func androidNormalizedWatermarkOpacity(_ value: Int) -> Int { min(max(value, 1), 100) }

private func androidWatermarkSizeToken(_ watermark: PhotoFrameWatermark) -> String {
    let size = androidNormalizedWatermarkSize(watermark.sizePercent) + 49
    switch (watermark.content, size) {
    case (.text, 58): return "SMALL"
    case (.text, 75): return "MEDIUM"
    case (.text, 100): return "LARGE"
    case (.image, 47): return "SMALL"
    case (.image, 69): return "MEDIUM"
    case (.image, 100): return "LARGE"
    default: return "\(size)P"
    }
}

private func androidWatermarkOpacityToken(_ value: Int) -> String {
    switch androidNormalizedWatermarkOpacity(value) {
    case 40: return "SUBTLE"
    case 72: return "STANDARD"
    case 100: return "STRONG"
    default: return "\(androidNormalizedWatermarkOpacity(value))P"
    }
}

private func androidNormalizedDatePattern(_ value: String) -> String {
    let allowed = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "MM-dd-yyyy"]
    return allowed.contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
        ? value.trimmingCharacters(in: .whitespacesAndNewlines) : "yyyy-MM-dd"
}

private func androidNormalizedTimePattern(_ value: String) -> String {
    let allowed = ["HH:mm", "HH:mm:ss", "HH.mm", "HH.mm.ss"]
    return allowed.contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
        ? value.trimmingCharacters(in: .whitespacesAndNewlines) : "HH:mm:ss"
}

private func androidMetadataFingerprintToken(_ preset: PhotoFramePreset, _ metadata: PhotoFrameMetadataSettings) -> String? {
    let defaults = PhotoFrameMetadataSettings.defaults(for: preset)
    var rendered = metadata
    if !rendered.showDate { rendered.datePattern = defaults.datePattern }
    if !rendered.showTime { rendered.timePattern = defaults.timePattern }
    rendered.datePattern = androidNormalizedDatePattern(rendered.datePattern)
    rendered.timePattern = androidNormalizedTimePattern(rendered.timePattern)
    rendered.showAddress = false
    rendered.widthPercent = preset == .immersive ? 100 : normalizePhotoFrameWidthPercent(rendered.widthPercent)
    let supportsBackdrop = preset.supportsBackdropControls
    rendered.backgroundBlurPercent = supportsBackdrop ? normalizePhotoFrameBackdropPercent(rendered.backgroundBlurPercent) : 100
    rendered.backgroundMaskPercent = supportsBackdrop ? normalizePhotoFrameBackdropPercent(rendered.backgroundMaskPercent) : 100
    guard rendered != defaults else { return nil }
    return PhotoEffectsStore.encodeAndroidMetadata([preset.rawValue: rendered])

}

private func androidWatermarkFingerprint(_ watermark: PhotoFrameWatermark, preset: PhotoFramePreset, metadata: PhotoFrameMetadataSettings) -> String {
    var base: [String]
    if watermark.enabled {
        let resolved = androidResolvedWatermarkPosition(preset, watermark.position)
        base = ["v=2"]
        if androidIsBrandFrame(preset) { base.append("brand-v=4") }
        if androidIsEditorialFrame(preset) { base.append("editorial-v=2") }
        if preset == .colorArchive { base.append("archive-layout-v=2") }
        if preset == .filmGallery { base.append("film-gallery-v=1") }
        if preset == .filmNegative { base.append("film-negative-v=2") }
        base += ["on", watermark.content.rawValue, androidWatermarkSizeToken(watermark),
                 resolved.rawValue, "opacity=\(androidWatermarkOpacityToken(watermark.opacityPercent))"]
        if watermark.content == .text {
            base += [watermark.displayText, watermark.font.rawValue, watermark.color.rawValue,
                     "effect=\(watermark.effect.rawValue)"]
        } else {
            let hash = watermark.imageHash?.lowercased()
            let valid = hash.flatMap { value in
                value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                    ? value : nil
            }
            // Android joinToString encodes a rejected nullable hash as "null".
            base.append(valid ?? "null")
        }
    } else if androidIsBrandFrame(preset) {
        base = ["brand-v=4", "off"]
    } else if androidIsEditorialFrame(preset) {
        base = ["editorial-v=2"]
        if preset == .colorArchive { base.append("archive-layout-v=2") }
        if preset == .filmGallery { base.append("film-gallery-v=1") }
        if preset == .filmNegative { base.append("film-negative-v=2") }
        base.append("off")
    } else {
        base = ["off"]
    }
    if let metadataToken = androidMetadataFingerprintToken(preset, metadata) {
        base += ["metadata=\(metadataToken)"]
    }
    if metadata.showCity || metadata.showRegion || metadata.showCoordinates || metadata.showAltitude {
        base.append("location-v=2")
    }
    if preset != .immersive {
        base.append("measured-layout-v=6")
        if preset == .frosted { base.append("glass-panel-v=2") }
    }
    if metadata.brandStyle == .logo { base.append("brand-logo-v=3") }
    return androidSHA256Hex(base.joined(separator: "\u{0}"), bytes: 6)
}

private func androidFilterFingerprint(_ filter: PhotoFilterSelection) -> String {
    // PhotoFrameExporter.photoFilterRenderFingerprint, Android render version 3.
    let adjustments = filter.lutAdjustments
    let identity = "v=3\u{0}\(filter.preset.id)"
        + "\u{0}i=\(filter.normalizedIntensityPercent)"
        + "\u{0}c=\(adjustments.contrast)\u{0}s=\(adjustments.saturation)"
        + "\u{0}h=\(adjustments.highlights)\u{0}sh=\(adjustments.shadows)"
    return androidSHA256Hex(identity, bytes: 4)
}

private func androidSHA256Hex(_ value: String, bytes: Int) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(bytes)
        .map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class PhotoEffectsStore: ObservableObject {
    nonisolated static let maximumWatermarkImageBytes = 20 * 1024 * 1024
    nonisolated static let maximumWatermarkImagePixelDimension = 2_048
    private nonisolated static let watermarkImageCache = PhotoEffectsWatermarkImageCache(capacity: 3)
    @Published private(set) var isEnabled: Bool
    @Published private(set) var settings: PhotoEffectsSettings
    @Published private(set) var watermarkImageImporting = false
    @Published private(set) var lastImportedWatermarkHash: String?
    @Published private(set) var watermarkImportRevision: UInt64 = 0
    private let defaults: UserDefaults
    private let key: String
    private let scope: Scope
    private let premiumAccess: PremiumAccess
    private var watermarkImportGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard, scope: Scope = .cameraTransfer,
         legacyDefaults: UserDefaults? = nil, premiumAccess: PremiumAccess = .shared,
         lutStore: PhotoLUTStore? = nil) {
        self.premiumAccess = premiumAccess
        // Android isolates phone-photo effects in the `local_photo_effects`
        // preference file.  UserDefaults suites provide the same isolation;
        // injected defaults are still honored for camera-transfer tests.
        let resolvedDefaults = scope == .localPhotos && defaults === UserDefaults.standard
            ? (UserDefaults(suiteName: "local_photo_effects") ?? defaults)
            : defaults
        self.defaults = resolvedDefaults
        self.scope = scope
        isEnabled = scope == .cameraTransfer ? (resolvedDefaults.object(forKey: "photo_effects_enabled") as? Bool ?? true) : true
        key = scope == .cameraTransfer ? "photoEffectsSettings.v1" : "localPhotoEffectsSettings.v1"
        if scope == .cameraTransfer, let value = Self.restoreAndroidTransferSettings(defaults: self.defaults) {
            let restored = Self.normalized(value, scope: scope)
            settings = restored
            // Android folds the legacy one-value intensity into the per-filter
            // map during restore, then removes the old key immediately.
            Self.persistAndroidTransferSettings(restored, defaults: self.defaults)
        } else if scope == .localPhotos, let value = Self.restoreAndroidLocalSettings(defaults: self.defaults) {
            let restored = Self.normalized(value, scope: scope)
            settings = restored
            Self.persistAndroidLocalSettings(restored, defaults: self.defaults)
        } else if let data = self.defaults.data(forKey: key), let value = try? JSONDecoder().decode(PhotoEffectsSettings.self, from: data) {
            settings = Self.normalized(value, scope: scope)
        } else if scope == .localPhotos,
                  let value = Self.migrateLegacyLocalFavorites(
                    from: legacyDefaults ?? (defaults === UserDefaults.standard ? .standard : defaults)
                  ) {
            settings = Self.normalized(value, scope: scope)
            Self.persistAndroidLocalSettings(settings, defaults: self.defaults)
            if let data = try? JSONEncoder().encode(settings) { self.defaults.set(data, forKey: key) }
        } else {
            settings = PhotoEffectsSettings()
            if let first = PhotoFilterCatalog.presets.first {
                settings.selectedFilter = .init(preset: first, intensityPercent: Np3FilterEngine.defaultIntensityPercent)
            }
            if scope == .localPhotos {
                // Android saves the initial local workbench snapshot as soon
                // as the page is composed. Mark this independent scope as
                // initialized even if the user leaves without editing, so a
                // later camera-setting favorite is never mistaken for a
                // first-run migration source.
                Self.persistAndroidLocalSettings(settings, defaults: self.defaults)
                if let data = try? JSONEncoder().encode(settings) {
                    self.defaults.set(data, forKey: key)
                }
            }
        }
        // LUT identity belongs to its role store, not the NP3 preference ID.
        // The original defaults argument intentionally keeps the shared photo-LUT
        // directory separate from the local-effects preference suite.
        let roleStore = lutStore ?? PhotoLUTStore(
            role: scope == .cameraTransfer ? .camera : .local, defaults: defaults)
        if photoEffectModuleIsVisible(settings.photoEffectModules, .lut),
           let selection = roleStore.restoreSelection() {
            var restored = settings
            restored.selectedFilter = selection
            restored.photoFilterEnabled = true
            update(restored)
        }
    }

    /// Transfer's master switch is not part of an editor recipe or the local
    /// photo workspace. Toggling it never rewrites modules, drafts or watermarks.
    func setEnabled(_ enabled: Bool) {
        guard scope == .cameraTransfer else { return }
        defaults.set(enabled, forKey: "photo_effects_enabled")
        if isEnabled != enabled { isEnabled = enabled }
    }

    func update(_ value: PhotoEffectsSettings) {
        let normalized = Self.normalized(value, scope: scope)
        if settings != normalized { settings = normalized }
        // Persistence remains explicit even for equal values: first-save and
        // legacy/shared defaults can still need writing. Only UI publication
        // is deduplicated; no draft, entitlement or disk-validation gate moves.
        if scope == .cameraTransfer {
            Self.persistAndroidTransferSettings(settings, defaults: self.defaults)
        } else {
            Self.persistAndroidLocalSettings(settings, defaults: self.defaults)
        }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        self.defaults.set(data, forKey: key)
    }

    /// Editor writes preserve paid preferences when access has changed during
    /// an open draft; rendering applies the separate effective-watermark policy.
    func updateFromEditor(_ value: PhotoEffectsSettings) {
        var accepted = value
        if !premiumAccess.isPro {
            accepted.watermark = settings.watermark
            for index in accepted.favoriteFrameEffects.indices {
                if let saved = settings.favoriteFrameEffects.first(where: {
                    $0.preset == accepted.favoriteFrameEffects[index].preset
                }) {
                    accepted.favoriteFrameEffects[index].watermark = saved.watermark
                } else {
                    // Android's free editor displays/captures its default
                    // watermark when adding a frame favorite. A stale paid
                    // draft must not introduce new custom parameters here.
                    accepted.favoriteFrameEffects[index].watermark = effectivePhotoFrameWatermark(
                        isPro: false, preference: settings.watermark,
                        borderEnabled: accepted.photoFrameBorderEnabled
                    )
                }
            }
        }
        update(accepted)
    }

    /// Transfer settings persist favorites/metadata immediately, independently
    /// of applying the active effects draft. Use the same permission boundary
    /// as an explicit save, including a refund while the popup is open.
    func persistEditorPreferences(from draft: PhotoEffectsSettings) {
        let value = settings.persistingEditorPreferences(from: draft)
        if value != settings { updateFromEditor(value) }
    }

    func beginDraft() -> PhotoEffectsSettings { settings }

    func beginWatermarkImageImport() -> UInt64? {
        guard premiumAccess.isPro, !watermarkImageImporting else { return nil }
        watermarkImportGeneration &+= 1
        watermarkImageImporting = true
        lastImportedWatermarkHash = nil
        return watermarkImportGeneration
    }

    /// Returns false for a result superseded by a later store-owned import.
    /// Keeping the token in the store (rather than either SwiftUI view) makes
    /// closing and reopening the settings popup unable to revive an old logo.
    func finishWatermarkImageImport(generation: UInt64, hash: String?) -> Bool {
        guard watermarkImportGeneration == generation else { return false }
        watermarkImageImporting = false
        guard premiumAccess.isPro else { return false }
        guard let hash else { return true }
        var updated = settings
        updated.watermark.content = .image
        updated.watermark.imageHash = hash
        if updated.photoFrameBorderEnabled,
           let index = updated.favoriteFrameEffects.firstIndex(where: {
               $0.preset == updated.photoFramePreset
           }) {
            updated.favoriteFrameEffects[index].watermark = updated.watermark
        }
        update(updated)
        guard settings.watermark.content == .image,
              settings.watermark.imageHash == hash else {
            // The generation completed, but normalization rejected the file.
            // Do not publish a hash that the effective Store does not contain.
            return true
        }
        lastImportedWatermarkHash = hash
        watermarkImportRevision &+= 1
        return true
    }

    /// Stores a watermark image in application support and returns its stable
    /// content hash, matching Android's private watermark copy semantics.
    func importWatermarkImage(data: Data) -> String? {
        Self.importWatermarkImageData(data)
    }

    /// Hashing, bitmap validation and disk I/O may process up to 20 MiB. Keep
    /// that work callable from a detached task so both photo-effect entry
    /// points match Android's Dispatchers.IO import instead of blocking UI.
    nonisolated static func importWatermarkImageData(_ data: Data) -> String? {
        guard !data.isEmpty,
              data.count <= Self.maximumWatermarkImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              decodeWatermarkImage(source) != nil else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZTransfer/Watermarks", isDirectory: true)
        let destination = directory.appendingPathComponent("\(hash).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            return hash
        } catch { return nil }
    }

    /// File-backed variant used by PhotosPicker. It mirrors Android's 128 KiB
    /// stream copy: reject immediately after the 20 MiB boundary, hash the
    /// original bytes, validate a bounded 2048-pixel decode, and atomically
    /// publish the private copy only after every check succeeds.
    nonisolated static func importWatermarkImageFile(_ sourceURL: URL) -> String? {
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZTransfer/Watermarks", isDirectory: true)
        var temporary: URL?
        defer {
            if let temporary { try? fileManager.removeItem(at: temporary) }
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = directory.appendingPathComponent("watermark-import-\(UUID().uuidString).part")
            temporary = temporaryURL
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else { return nil }
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: temporaryURL)
            var handlesClosed = false
            defer {
                if !handlesClosed {
                    try? input.close()
                    try? output.close()
                }
            }
            var hasher = SHA256()
            var copied = 0
            while true {
                let chunk = try input.read(upToCount: 128 * 1024) ?? Data()
                if chunk.isEmpty { break }
                copied += chunk.count
                guard copied <= Self.maximumWatermarkImageBytes else { return nil }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try input.close()
            try output.close()
            handlesClosed = true
            guard copied > 0,
                  let source = CGImageSourceCreateWithURL(temporaryURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
                  ((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0) > 0,
                  ((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0) > 0,
                  decodeWatermarkImage(source) != nil else {
                return nil
            }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let destination = directory.appendingPathComponent("\(hash).png")
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: temporaryURL)
            } else {
                do {
                    try fileManager.moveItem(at: temporaryURL, to: destination)
                } catch {
                    guard fileManager.fileExists(atPath: destination.path) else { throw error }
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }
            temporary = nil
            return hash
        } catch {
            return nil
        }
    }

    nonisolated static func watermarkImage(hash: String) -> UIImage? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZTransfer/Watermarks/\(hash).png")
        return watermarkImageCache.image(for: hash) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return decodeWatermarkImage(source)
        }
    }

    nonisolated static func resetWatermarkImageCache() {
        watermarkImageCache.removeAll()
    }

    nonisolated static var watermarkImageCacheCount: Int {
        watermarkImageCache.count
    }

    private nonisolated static func decodeWatermarkImage(_ source: CGImageSource) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumWatermarkImagePixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    private nonisolated static func watermarkImageFileExists(hash: String) -> Bool {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZTransfer/Watermarks/\(hash).png")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Android LocalPhotoEffectsPreferences is separate from TransferState.
    /// Reuse the model and editor, while preserving their independent choices.
    enum Scope { case cameraTransfer, localPhotos }

    private static func normalized(_ value: PhotoEffectsSettings, scope: Scope) -> PhotoEffectsSettings {
        var result = value
        result.applyModuleVisibility(value.photoEffectModules)
        var watermark = result.watermark
        let candidateHash = watermark.imageHash?.lowercased()
        let validHash: String?
        if let candidateHash,
           candidateHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
           watermarkImageFileExists(hash: candidateHash) {
            validHash = candidateHash
        } else {
            validHash = nil
        }
        watermark.imageHash = validHash
        if watermark.content == .image && validHash == nil { watermark.content = .text }
        watermark.text = scope == .cameraTransfer ? watermark.displayText : watermark.limitedText
        watermark.sizePercent = min(max(watermark.sizePercent, PhotoFrameWatermark.sizeRange.lowerBound), PhotoFrameWatermark.sizeRange.upperBound)
        watermark.opacityPercent = min(max(watermark.opacityPercent, PhotoFrameWatermark.opacityRange.lowerBound), PhotoFrameWatermark.opacityRange.upperBound)
        result.watermark = watermark
        let validFilterKeys = Set(Np3FilterCatalog.presets.map(\.catalogKey))
        result.filterIntensities = value.filterIntensities.reduce(into: [:]) { partial, item in
            let key = Np3FilterCatalog.preset(id: item.key)?.catalogKey ?? item.key
            guard validFilterKeys.contains(key), partial[key] == nil else { return }
            partial[key] = Np3FilterEngine.normalizeIntensity(item.value)
        }
        var seenFilters = Set<String>()
        result.favoriteFilterIDs = value.favoriteFilterIDs.map(PhotoEffectsSettings.filterKey)
            .filter { validFilterKeys.contains($0) && seenFilters.insert($0).inserted }
        if let selected = value.selectedFilter {
            if selected.preset.id.hasPrefix("cube:"),
               PhotoLUTRuntime.contains(digest: String(selected.preset.id.dropFirst(5))) {
                // Cube recipes are content-addressed runtime tables, not NP3
                // catalog entries. Keep their original display name and strength.
                var normalized = selected
                normalized.intensityPercent = selected.normalizedIntensityPercent
                normalized.lutAdjustments = selected.lutAdjustments.normalized
                result.selectedFilter = normalized
            } else if let preset = PhotoFilterCatalog.resolve(selected.preset.id) {
                let intensity = selected.normalizedIntensityPercent
                result.selectedFilter = .init(preset: preset, intensityPercent: intensity)
                let key = PhotoEffectsSettings.filterKey(preset.id)
                if result.filterIntensities[key] == nil {
                    result.filterIntensities[key] = intensity
                }
            } else {
                result.selectedFilter = nil
                result.photoFilterEnabled = false
            }
        }
        result.photoFilterEnabled = result.photoFilterEnabled && result.selectedFilter != nil
        // Keep the old set field in sync for preferences written by the first
        // iOS workbench build, while the effect list remains the source of truth.
        var seenFrames = Set<PhotoFramePreset>()
        result.favoriteFrameEffects = result.favoriteFrameEffects.compactMap { favorite in
            guard seenFrames.insert(favorite.preset).inserted else { return nil }
            var normalized = favorite
            normalized.watermark.sizePercent = min(max(
                normalized.watermark.sizePercent, PhotoFrameWatermark.sizeRange.lowerBound
            ), PhotoFrameWatermark.sizeRange.upperBound)
            normalized.watermark.opacityPercent = min(max(
                normalized.watermark.opacityPercent, PhotoFrameWatermark.opacityRange.lowerBound
            ), PhotoFrameWatermark.opacityRange.upperBound)
            return normalized
        }
        let knownPresets = Set(result.favoriteFrameEffects.map(\.preset))
        for preset in PhotoFramePreset.allCases where result.favoriteFramePresets.contains(preset) && !knownPresets.contains(preset) {
            result.favoriteFrameEffects.append(.init(preset: preset, watermark: result.watermark))
        }
        result.favoriteFramePresets.formUnion(result.favoriteFrameEffects.map(\.preset))
        result.metadataByPreset = value.metadataByPreset.reduce(into: [:]) { partial, entry in
            guard let preset = PhotoFramePreset(rawValue: entry.key) else { return }
            var metadata = entry.value
            metadata.widthPercent = normalizePhotoFrameWidthPercent(metadata.widthPercent)
            metadata.backgroundBlurPercent = normalizePhotoFrameBackdropPercent(metadata.backgroundBlurPercent)
            metadata.backgroundMaskPercent = normalizePhotoFrameBackdropPercent(metadata.backgroundMaskPercent)
            metadata.showAddress = false
            metadata.datePattern = androidNormalizedDatePattern(metadata.datePattern)
            metadata.timePattern = androidNormalizedTimePattern(metadata.timePattern)
            if scope == .localPhotos {
                metadata.showCoordinates = false
                metadata.showAltitude = false
                metadata.showAddress = false
                metadata.showCity = false
                metadata.showRegion = false
            }
            if metadata != PhotoFrameMetadataSettings.defaults(for: preset) {
                partial[preset.rawValue] = metadata
            }
        }
        result.metadata = result.metadataByPreset[result.photoFramePreset.rawValue]
            ?? PhotoFrameMetadataSettings.defaults(for: result.photoFramePreset)
        return result
    }

    private static func migrateLegacyLocalFavorites(from defaults: UserDefaults) -> PhotoEffectsSettings? {
        let filterRaw = defaults.string(forKey: "favorite_photo_filters_v1")
        let frameRaw = defaults.string(forKey: "favorite_frame_effects_v1")
        guard filterRaw != nil || frameRaw != nil else { return nil }
        var value = PhotoEffectsSettings()
        value.favoriteFilterIDs = decodeAndroidFavorites(filterRaw)
        value.favoriteFrameEffects = decodeAndroidFrameFavorites(frameRaw, watermark: value.watermark)
        value.favoriteFramePresets = Set(value.favoriteFrameEffects.map(\.preset))
        if let first = PhotoFilterCatalog.presets.first {
            value.selectedFilter = .init(preset: first,
                                         intensityPercent: Np3FilterEngine.defaultIntensityPercent)
        }
        return value
    }

    // MARK: Android preference compatibility

    /// Android keeps camera-transfer effects as individual entries in the
    /// `ztransfer` preferences file.  The first iOS implementation stored one
    /// private JSON blob, which made an existing Android configuration appear
    /// lost after switching platforms.  Read and write the Android keys
    /// directly; the old blob remains as a one-way fallback for upgrades.
    private static func restoreAndroidTransferSettings(defaults: UserDefaults) -> PhotoEffectsSettings? {
        // Favorites, per-filter intensities and metadata are committed while
        // the secondary editor is still open on Android. Treat every effect
        // preference as a valid restore marker so an app termination before
        // the draft itself is committed cannot hide those durable edits.
        let markerKeys = [
            "photo_frame_enabled", "photo_frame_border_enabled", "photo_frame_preset",
            "photo_frame_metadata_settings_v1", "photo_frame_branding_enabled",
            "photo_frame_watermark_content", "photo_frame_watermark_text",
            "photo_frame_watermark_image_hash", "photo_frame_watermark_font",
            "photo_frame_watermark_size", "photo_frame_watermark_size_scale_version",
            "photo_frame_watermark_position", "photo_frame_watermark_color",
            "photo_frame_watermark_opacity", "photo_frame_watermark_effect",
            "photo_filter_enabled", "photo_filter_selected_id", "photo_filter_intensity",
            "photo_filter_intensities_v1", "favorite_photo_filters_v1",
            "favorite_frame_effects_v1", "photo_effect_modules",
        ]
        guard markerKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        var value = PhotoEffectsSettings()
        value.photoEffectModules = normalizePhotoEffectModules(defaults.object(forKey: "photo_effect_modules") as? Int ?? allPhotoEffectModules)
        value.photoFrameEnabled = defaults.object(forKey: "photo_frame_enabled") as? Bool ?? false
        value.photoFrameBorderEnabled = defaults.object(forKey: "photo_frame_border_enabled") as? Bool ?? true
        value.photoFramePreset = PhotoFramePreset(rawValue: defaults.string(forKey: "photo_frame_preset") ?? "MIST") ?? .mist
        let storedFilterID = defaults.string(forKey: "photo_filter_selected_id")
        let restoredPreset = storedFilterID.flatMap(PhotoFilterCatalog.resolve)
            ?? PhotoFilterCatalog.presets.first
        var intensities = decodeAndroidIntensities(
            defaults.string(forKey: "photo_filter_intensities_v1")
        )
        if let restoredPreset {
            let key = PhotoEffectsSettings.filterKey(restoredPreset.id)
            let legacy = defaults.object(forKey: "photo_filter_intensity") as? Int
            let intensity = intensities[key]
                ?? legacy.map(Np3FilterEngine.normalizeIntensity)
                ?? Np3FilterEngine.defaultIntensityPercent
            intensities[key] = intensity
            value.selectedFilter = PhotoFilterSelection(
                preset: restoredPreset, intensityPercent: intensity
            )
        }
        value.filterIntensities = intensities
        value.photoFilterEnabled = storedFilterID == restoredPreset?.id &&
            (defaults.object(forKey: "photo_filter_enabled") as? Bool ?? false)
        value.favoriteFilterIDs = decodeAndroidFavorites(defaults.string(forKey: "favorite_photo_filters_v1"))
        let content = PhotoFrameWatermarkContent(rawValue: defaults.string(forKey: "photo_frame_watermark_content") ?? "TEXT") ?? .text
        let usesLegacySizeScale = defaults.object(forKey: "photo_frame_watermark_size") != nil &&
            defaults.integer(forKey: "photo_frame_watermark_size_scale_version") < 2
        value.watermark = PhotoFrameWatermark(
            enabled: defaults.object(forKey: "photo_frame_branding_enabled") as? Bool ?? true,
            content: content,
            text: defaults.string(forKey: "photo_frame_watermark_text") ?? PhotoFrameWatermark.defaultText,
            imageHash: defaults.string(forKey: "photo_frame_watermark_image_hash"),
            font: PhotoFrameWatermarkFont(rawValue: defaults.string(forKey: "photo_frame_watermark_font") ?? "CALLIGRAPHY") ?? .calligraphy,
            sizePercent: restoredPhotoFrameWatermarkSizePercent(
                defaults.object(forKey: "photo_frame_watermark_size"),
                content: content,
                usesLegacyScale: usesLegacySizeScale
            ),
            position: PhotoFrameWatermarkPosition(rawValue: defaults.string(forKey: "photo_frame_watermark_position") ?? "AUTO") ?? .auto,
            color: PhotoFrameWatermarkColor(rawValue: defaults.string(forKey: "photo_frame_watermark_color") ?? "ADAPTIVE") ?? .adaptive,
            opacityPercent: restoredPhotoFrameWatermarkOpacityPercent(
                defaults.object(forKey: "photo_frame_watermark_opacity")
            ),
            effect: PhotoFrameWatermarkEffect(rawValue: defaults.string(forKey: "photo_frame_watermark_effect") ?? "AUTO") ?? .auto)
        value.metadataByPreset = decodeAndroidMetadata(defaults.string(forKey: "photo_frame_metadata_settings_v1"))
        value.metadata = value.metadataByPreset[value.photoFramePreset.rawValue] ?? PhotoFrameMetadataSettings.defaults(for: value.photoFramePreset)
        value.favoriteFrameEffects = decodeAndroidFrameFavorites(defaults.string(forKey: "favorite_frame_effects_v1"), watermark: value.watermark)
        value.favoriteFramePresets = Set(value.favoriteFrameEffects.map(\.preset))
        return value
    }

    private static func persistAndroidTransferSettings(_ value: PhotoEffectsSettings, defaults: UserDefaults) {
        defaults.set(value.photoEffectModules, forKey: "photo_effect_modules")
        defaults.set(value.photoFrameEnabled, forKey: "photo_frame_enabled")
        defaults.set(value.photoFrameBorderEnabled, forKey: "photo_frame_border_enabled")
        defaults.set(value.photoFramePreset.rawValue, forKey: "photo_frame_preset")
        defaults.set(value.photoFilterEnabled && value.selectedFilter != nil, forKey: "photo_filter_enabled")
        if let selected = value.selectedFilter { defaults.set(selected.preset.id, forKey: "photo_filter_selected_id") }
        else { defaults.removeObject(forKey: "photo_filter_selected_id") }
        defaults.set(encodeAndroidIntensities(value.filterIntensities), forKey: "photo_filter_intensities_v1")
        defaults.removeObject(forKey: "photo_filter_intensity")
        defaults.set(encodeAndroidFavorites(value.favoriteFilterIDs), forKey: "favorite_photo_filters_v1")
        defaults.set(value.watermark.enabled, forKey: "photo_frame_branding_enabled")
        defaults.set(value.watermark.content.rawValue, forKey: "photo_frame_watermark_content")
        defaults.set(value.watermark.text, forKey: "photo_frame_watermark_text")
        if let hash = value.watermark.imageHash { defaults.set(hash, forKey: "photo_frame_watermark_image_hash") } else { defaults.removeObject(forKey: "photo_frame_watermark_image_hash") }
        defaults.set(value.watermark.font.rawValue, forKey: "photo_frame_watermark_font")
        defaults.set(value.watermark.sizePercent, forKey: "photo_frame_watermark_size")
        defaults.set(2, forKey: "photo_frame_watermark_size_scale_version")
        defaults.set(value.watermark.position.rawValue, forKey: "photo_frame_watermark_position")
        defaults.set(value.watermark.color.rawValue, forKey: "photo_frame_watermark_color")
        defaults.set(value.watermark.opacityPercent, forKey: "photo_frame_watermark_opacity")
        defaults.set(value.watermark.effect.rawValue, forKey: "photo_frame_watermark_effect")
        defaults.set(encodeAndroidMetadata(value.metadataByPreset), forKey: "photo_frame_metadata_settings_v1")
        defaults.set(encodeAndroidFrameFavorites(value.favoriteFrameEffects), forKey: "favorite_frame_effects_v1")
    }

    private static func restoreAndroidLocalSettings(defaults: UserDefaults) -> PhotoEffectsSettings? {
        guard defaults.object(forKey: "settings_version") != nil || defaults.object(forKey: "frame_preset") != nil else { return nil }
        var value = PhotoEffectsSettings()
        value.photoFrameEnabled = defaults.object(forKey: "decoration_enabled") as? Bool ?? false
        value.photoEffectModules = normalizePhotoEffectModules(defaults.object(forKey: "photo_effect_modules") as? Int ?? allPhotoEffectModules)
        value.photoFrameBorderEnabled = defaults.object(forKey: "border_enabled") as? Bool ?? true
        value.photoFramePreset = PhotoFramePreset(rawValue: defaults.string(forKey: "frame_preset") ?? "MIST") ?? .mist
        value.metadataByPreset = decodeAndroidMetadata(defaults.string(forKey: "frame_metadata_settings_v1"))
        value.metadata = value.metadataByPreset[value.photoFramePreset.rawValue] ?? PhotoFrameMetadataSettings.defaults(for: value.photoFramePreset)
        value.photoFilterEnabled = defaults.object(forKey: "filter_enabled") as? Bool ?? false
        let intensities = decodeAndroidIntensities(defaults.string(forKey: "filter_intensities_v1"))
        value.filterIntensities = intensities
        if let id = defaults.string(forKey: "filter_id"), let preset = PhotoFilterCatalog.resolve(id) {
            let key = Np3FilterCatalog.preset(id: id)?.catalogKey ?? id
            value.selectedFilter = PhotoFilterSelection(preset: preset, intensityPercent: intensities[key] ?? (defaults.object(forKey: "filter_intensity") as? Int ?? Np3FilterEngine.defaultIntensityPercent))
        }
        value.favoriteFilterIDs = decodeAndroidFavorites(defaults.string(forKey: "favorite_photo_filters_v1"))
        value.watermark = PhotoFrameWatermark(
            enabled: defaults.object(forKey: "watermark_enabled") as? Bool ?? true,
            content: PhotoFrameWatermarkContent(rawValue: defaults.string(forKey: "watermark_content") ?? "TEXT") ?? .text,
            text: defaults.string(forKey: "watermark_text") ?? PhotoFrameWatermark.defaultText,
            imageHash: defaults.string(forKey: "watermark_image_hash"),
            font: PhotoFrameWatermarkFont(rawValue: defaults.string(forKey: "watermark_font") ?? "CALLIGRAPHY") ?? .calligraphy,
            sizePercent: defaults.object(forKey: "watermark_size") as? Int ?? 80,
            position: PhotoFrameWatermarkPosition(rawValue: defaults.string(forKey: "watermark_position") ?? "AUTO") ?? .auto,
            color: PhotoFrameWatermarkColor(rawValue: defaults.string(forKey: "watermark_color") ?? "ADAPTIVE") ?? .adaptive,
            opacityPercent: defaults.object(forKey: "watermark_opacity") as? Int ?? 72,
            effect: PhotoFrameWatermarkEffect(rawValue: defaults.string(forKey: "watermark_effect") ?? "AUTO") ?? .auto)
        value.favoriteFrameEffects = decodeAndroidFrameFavorites(defaults.string(forKey: "favorite_frame_effects_v1"), watermark: value.watermark)
        value.favoriteFramePresets = Set(value.favoriteFrameEffects.map(\.preset))
        return value
    }

    private static func persistAndroidLocalSettings(_ value: PhotoEffectsSettings, defaults: UserDefaults) {
        defaults.set(3, forKey: "settings_version")
        defaults.set(value.photoFrameEnabled, forKey: "decoration_enabled")
        defaults.set(value.photoEffectModules, forKey: "photo_effect_modules")
        defaults.set(value.photoFrameBorderEnabled, forKey: "border_enabled")
        defaults.set(value.photoFramePreset.rawValue, forKey: "frame_preset")
        defaults.set(encodeAndroidMetadata(value.metadataByPreset), forKey: "frame_metadata_settings_v1")
        defaults.set(value.watermark.enabled, forKey: "watermark_enabled")
        defaults.set(value.watermark.content.rawValue, forKey: "watermark_content")
        defaults.set(value.watermark.text, forKey: "watermark_text")
        if let hash = value.watermark.imageHash { defaults.set(hash, forKey: "watermark_image_hash") } else { defaults.removeObject(forKey: "watermark_image_hash") }
        defaults.set(value.watermark.font.rawValue, forKey: "watermark_font")
        defaults.set(value.watermark.sizePercent, forKey: "watermark_size")
        defaults.set(value.watermark.position.rawValue, forKey: "watermark_position")
        defaults.set(value.watermark.color.rawValue, forKey: "watermark_color")
        defaults.set(value.watermark.opacityPercent, forKey: "watermark_opacity")
        defaults.set(value.watermark.effect.rawValue, forKey: "watermark_effect")
        if let selected = value.selectedFilter { defaults.set(selected.preset.id, forKey: "filter_id") } else { defaults.removeObject(forKey: "filter_id") }
        defaults.set(value.photoFilterEnabled && value.selectedFilter != nil, forKey: "filter_enabled")
        defaults.set(encodeAndroidIntensities(value.filterIntensities), forKey: "filter_intensities_v1")
        defaults.removeObject(forKey: "filter_intensity")
        defaults.set(encodeAndroidFavorites(value.favoriteFilterIDs), forKey: "favorite_photo_filters_v1")
        defaults.set(encodeAndroidFrameFavorites(value.favoriteFrameEffects), forKey: "favorite_frame_effects_v1")
    }

    private static func decodeAndroidFavorites(_ raw: String?) -> [String] {
        raw?.split(separator: ";").map { String($0).split(separator: ",").first.map(String.init) ?? "" }.filter { !$0.isEmpty } ?? []
    }
    private static func encodeAndroidFavorites(_ ids: [String]) -> String { ids.joined(separator: ";") }
    private static func decodeAndroidIntensities(_ raw: String?) -> [String: Int] {
        var result: [String: Int] = [:]
        let validKeys = Set(Np3FilterCatalog.presets.map(\.catalogKey))
        for entry in (raw ?? "").split(separator: ";") {
            let f = entry.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 2, let n = Int(f[1]) else { continue }
            let key = String(f[0])
            guard validKeys.contains(key), result[key] == nil else { continue }
            result[key] = Np3FilterEngine.normalizeIntensity(n)
        }
        return result
    }
    private static func encodeAndroidIntensities(_ values: [String: Int]) -> String {
        values.keys.sorted().compactMap { key in values[key].map { "\(key),\(Np3FilterEngine.normalizeIntensity($0))" } }.joined(separator: ";")
    }
    private static func decodeAndroidFrameFavorites(_ raw: String?, watermark: PhotoFrameWatermark) -> [PhotoFrameFavorite] {
        var seen = Set<PhotoFramePreset>()
        return (raw ?? "").split(separator: ";").compactMap { entry in
            let f = entry.split(separator: ",", omittingEmptySubsequences: false)
            guard [9, 10, 12].contains(f.count), let preset = PhotoFramePreset(rawValue: String(f[0])),
                  seen.insert(preset).inserted, let enabled = Bool(String(f[1])),
                  let content = PhotoFrameWatermarkContent(rawValue: String(f[2])), let font = PhotoFrameWatermarkFont(rawValue: String(f[3])),
                  let size = Int(f[4]), let position = PhotoFrameWatermarkPosition(rawValue: String(f[5])), let color = PhotoFrameWatermarkColor(rawValue: String(f[6])),
                  let opacity = Int(f[7]), let effect = PhotoFrameWatermarkEffect(rawValue: String(f[8])) else { return nil }
            guard let width = f.count >= 10 ? Int(f[9]) : 100,
                  let blur = f.count == 12 ? Int(f[10]) : 100,
                  let mask = f.count == 12 ? Int(f[11]) : 100 else { return nil }
            return PhotoFrameFavorite(preset: preset, watermark: watermark.copy(enabled: enabled, content: content, font: font, sizePercent: size, position: position, color: color, opacityPercent: opacity, effect: effect),
                                      frameWidthPercent: width, backgroundBlurPercent: blur, backgroundMaskPercent: mask)
        }
    }
    private static func encodeAndroidFrameFavorites(_ values: [PhotoFrameFavorite]) -> String {
        values.map { f in
            let size = min(max(f.watermark.sizePercent, PhotoFrameWatermark.sizeRange.lowerBound),
                           PhotoFrameWatermark.sizeRange.upperBound)
            let opacity = min(max(f.watermark.opacityPercent, PhotoFrameWatermark.opacityRange.lowerBound),
                              PhotoFrameWatermark.opacityRange.upperBound)
            var fields = [f.preset.rawValue, String(f.watermark.enabled), f.watermark.content.rawValue,
                          f.watermark.font.rawValue, String(size), f.watermark.position.rawValue,
                          f.watermark.color.rawValue, String(opacity), f.watermark.effect.rawValue,
                          String(normalizePhotoFrameWidthPercent(f.frameWidthPercent))]
            if f.backgroundBlurPercent != 100 || f.backgroundMaskPercent != 100 {
                fields += [String(normalizePhotoFrameBackdropPercent(f.backgroundBlurPercent)),
                           String(normalizePhotoFrameBackdropPercent(f.backgroundMaskPercent))]
            }
            return fields.joined(separator: ",")
        }.joined(separator: ";")
    }
    private static func decodeAndroidMetadata(_ raw: String?) -> [String: PhotoFrameMetadataSettings] {
        var result: [String: PhotoFrameMetadataSettings] = [:]
        for entry in (raw ?? "").split(separator: ";") {
            let f = entry.split(separator: "|", omittingEmptySubsequences: false)
            guard [9, 10, 12, 13, 14, 15, 16, 18].contains(f.count),
                  let preset = PhotoFramePreset(rawValue: String(f[0])),
                  result[preset.rawValue] == nil else { continue }
            let hasLensModel = f.count >= 10
            let hasLocation = f.count >= 12
            let hasLegacyAddressSlot = f.count == 13
            let booleanEnd: Int
            switch f.count {
            case 13: booleanEnd = 11
            case 12, 14, 15, 16, 18: booleanEnd = 10
            case 10: booleanEnd = 8
            default: booleanEnd = 7
            }
            // Android's former 13-field form stored address at index 8. The
            // feature was removed, so skip that token while retaining the
            // following coordinate and altitude flags forever.
            let booleanIndices = hasLegacyAddressSlot
                ? [1, 2, 3, 4, 5, 6, 7, 9, 10]
                : Array(1..<booleanEnd)
            let bools = booleanIndices.map { Bool(String(f[$0])) }
            guard bools.allSatisfy({ $0 != nil }) else { continue }
            var value = PhotoFrameMetadataSettings(
                showDate: bools[0]!, showTime: bools[1]!,
                showFocalLength: bools[2]!, showExposure: bools[3]!,
                showBrand: bools[4]!, showModel: bools[5]!,
                showLensModel: hasLensModel ? bools[6]! : false,
                showCoordinates: hasLocation ? bools[7]! : false,
                showAltitude: hasLocation ? bools[8]! : false,
                datePattern: androidNormalizedDatePattern(String(f[booleanEnd])),
                timePattern: androidNormalizedTimePattern(String(f[booleanEnd + 1]))
            )
            if f.count >= 14 {
                guard let city = Bool(String(f[12])), let region = Bool(String(f[13])) else { continue }
                value.showCity = city; value.showRegion = region
            }
            if f.count >= 15 {
                guard ["TEXT", "LOGO"].contains(String(f[14])),
                      let style = PhotoFrameBrandStyle(rawValue: f[14].lowercased()) else { continue }
                value.brandStyle = style
            }
            if f.count >= 16 {
                guard let width = Int32(f[15]) else { continue }
                value.widthPercent = normalizePhotoFrameWidthPercent(Int(width))
            }
            if f.count == 18 {
                guard let blur = Int32(f[16]), let mask = Int32(f[17]) else { continue }
                value.backgroundBlurPercent = normalizePhotoFrameBackdropPercent(Int(blur))
                value.backgroundMaskPercent = normalizePhotoFrameBackdropPercent(Int(mask))
            }
            if value != .defaults(for: preset) { result[preset.rawValue] = value }
        }
        return result
    }
    fileprivate nonisolated static func encodeAndroidMetadata(_ values: [String: PhotoFrameMetadataSettings]) -> String {
        values.keys.sorted().compactMap { key -> String? in
            guard let p = PhotoFramePreset(rawValue: key), let v = values[key] else { return nil }
            guard v != .defaults(for: p) else { return nil }
            var fields = [p.rawValue, String(v.showDate), String(v.showTime), String(v.showFocalLength), String(v.showExposure), String(v.showBrand), String(v.showModel), String(v.showLensModel), String(v.showCoordinates), String(v.showAltitude), v.datePattern, v.timePattern]
            let backdrop = v.backgroundBlurPercent != 100 || v.backgroundMaskPercent != 100
            if backdrop || v.widthPercent != 100 || v.brandStyle == .logo || v.showCity || v.showRegion {
                fields += [String(v.showCity), String(v.showRegion)]
            }
            if backdrop || v.widthPercent != 100 || v.brandStyle == .logo { fields.append(v.brandStyle.rawValue.uppercased()) }
            if backdrop || v.widthPercent != 100 { fields.append(String(normalizePhotoFrameWidthPercent(v.widthPercent))) }
            if backdrop { fields += [String(normalizePhotoFrameBackdropPercent(v.backgroundBlurPercent)), String(normalizePhotoFrameBackdropPercent(v.backgroundMaskPercent))] }
            return fields.joined(separator: "|")
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

/// Encodes rendered pixels as a highest-quality JPEG while preserving the
/// same photographic EXIF/GPS subset as Android's PhotoFrameExporter. Pixels
/// are already orientation-normalized by the renderer, so orientation and
/// dimensions are always rewritten for the new canvas.
enum PhotoEffectsJPEGEncoder {
    static func encode(
        _ rendered: UIImage,
        copyingMetadataFrom sourceData: Data,
        cameraMetadata: PhotoFrameMetadata? = nil
    ) -> Data? {
        let source = CGImageSourceCreateWithData(sourceData as CFData, nil)
        return encode(rendered, source: source, cameraMetadata: cameraMetadata)
    }

    static func encode(
        _ rendered: UIImage,
        copyingMetadataFrom sourceURL: URL,
        cameraMetadata: PhotoFrameMetadata? = nil
    ) -> Data? {
        let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)
        return encode(rendered, source: source, cameraMetadata: cameraMetadata)
    }

    private static func encode(
        _ rendered: UIImage,
        source: CGImageSource?,
        cameraMetadata: PhotoFrameMetadata?
    ) -> Data? {
        guard let image = rendered.cgImage else { return nil }
        let sourceProperties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as NSDictionary?
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyPixelWidth: image.width,
            kCGImagePropertyPixelHeight: image.height,
        ]

        let tiffSource = sourceProperties?[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let tiffKeys: [CFString] = [
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
            kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime,
        ]
        let tiff = copiedValues(from: tiffSource, keys: tiffKeys)
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }

        let exifSource = sourceProperties?[kCGImagePropertyExifDictionary] as? NSDictionary
        let exifKeys: [CFString] = [
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
            kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
            kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength,
            kCGImagePropertyExifFocalLenIn35mmFilm, kCGImagePropertyExifLensMake,
            kCGImagePropertyExifLensModel, kCGImagePropertyExifExposureProgram,
            kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifMeteringMode,
            kCGImagePropertyExifFlash, kCGImagePropertyExifWhiteBalance,
            kCGImagePropertyExifColorSpace,
        ]
        var exif = copiedValues(from: exifSource, keys: exifKeys)
        exif[kCGImagePropertyExifPixelXDimension] = image.width
        exif[kCGImagePropertyExifPixelYDimension] = image.height
        properties[kCGImagePropertyExifDictionary] = exif

        let gpsSource = sourceProperties?[kCGImagePropertyGPSDictionary] as? NSDictionary
        let gpsKeys: [CFString] = [
            kCGImagePropertyGPSVersion, kCGImagePropertyGPSLatitudeRef,
            kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLongitudeRef,
            kCGImagePropertyGPSLongitude, kCGImagePropertyGPSAltitudeRef,
            kCGImagePropertyGPSAltitude, kCGImagePropertyGPSTimeStamp,
            kCGImagePropertyGPSDateStamp, kCGImagePropertyGPSProcessingMethod,
            kCGImagePropertyGPSSpeedRef, kCGImagePropertyGPSSpeed,
            kCGImagePropertyGPSTrackRef, kCGImagePropertyGPSTrack,
        ]
        var gps = copiedValues(from: gpsSource, keys: gpsKeys)
        if let latitude = cameraMetadata?.latitude,
           let longitude = cameraMetadata?.longitude,
           validPhotoFrameCoordinates(latitude, longitude) {
            gps[kCGImagePropertyGPSLatitude] = abs(latitude)
            gps[kCGImagePropertyGPSLatitudeRef] = latitude < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude] = abs(longitude)
            gps[kCGImagePropertyGPSLongitudeRef] = longitude < 0 ? "W" : "E"
        }
        if let altitude = cameraMetadata?.altitude,
           altitude.isFinite, altitude != 0 {
            gps[kCGImagePropertyGPSAltitude] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
        }
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func copiedValues(
        from source: NSDictionary?, keys: [CFString]
    ) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        for key in keys {
            if let value = source?[key] { result[key] = value }
        }
        return result
    }
}
