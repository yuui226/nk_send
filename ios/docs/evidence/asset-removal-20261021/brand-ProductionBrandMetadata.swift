import Foundation

enum PhotoFramePreset: String, CaseIterable, Codable, Sendable {
    case mist = "MIST", cinema = "CINEMA", minimal = "MINIMAL", frosted = "FROSTED"
    case plaque = "PLAQUE", immersive = "IMMERSIVE", brandInset = "BRAND_INSET", brandGallery = "BRAND_GALLERY"
    case classicSignature = "CLASSIC_SIGNATURE", galleryMat = "GALLERY_MAT", colorArchive = "COLOR_ARCHIVE"
    case filmGallery = "FILM_GALLERY", filmEdge = "FILM_EDGE"
    case filmNegative = "FILM_NEGATIVE", parameterPoster = "PARAMETER_POSTER"
}

enum PhotoFrameBrandStyle: String, Codable, CaseIterable, Sendable { case text, logo }

func normalizePhotoFrameWidthPercent(_ value: Int) -> Int { min(max(value, 60), 200).rounded(toMultipleOf: 5) }

func normalizePhotoFrameBackdropPercent(_ value: Int) -> Int { min(max(value, 0), 200).rounded(toMultipleOf: 10) }

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
    var brandStyle: PhotoFrameBrandStyle = .text {
        didSet { if brandStyle != .text { brandStyle = .text } }
    }
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
        self.showAddress = showAddress; self.showCity = showCity; self.showRegion = showRegion; self.brandStyle = .text
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
        // Accept the former `logo` payload without discarding the rest of the
        // recipe, but never restore its removed graphical rendering mode.
        _ = try c.decodeIfPresent(PhotoFrameBrandStyle.self, forKey: .brandStyle)
        brandStyle = .text
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

extension PhotoFrameMetadataSettings {
    /// User-approved iOS difference from Android's off → text → logo cycle:
    /// only ordinary brand text and off remain; other metadata is untouched.
    mutating func cycleBrandStyle() {
        showBrand.toggle()
        brandStyle = .text
    }

    var brandControlLabelKey: String {
        guard showBrand else { return "photo_frame_metadata_brand" }
        return "photo_frame_metadata_brand_text"
    }
}
