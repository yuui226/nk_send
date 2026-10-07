import Foundation

enum PhotoFrameBrand: String, CaseIterable, Sendable {
    case nikon, fujifilm, panasonic, samsung, motorola, oneplus, huawei, xiaomi, honor, apple, google, nokia, leica, sony, oppo, vivo, dji
    static func resolve(_ make: String?) -> Self? {
        guard let make else { return nil }
        let value = make.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("nikon") { return .nikon }
        return allCases.dropFirst().first { value == $0.rawValue || value.hasPrefix($0.rawValue + " ") }
    }
    var vectorAssetName: String { "brand_\(rawValue)" }
    var logoHeightFactor: CGFloat {
        switch self {
        case .apple: 1.08
        case .huawei, .xiaomi, .leica, .motorola, .oneplus, .google: 1.0
        case .dji: 0.95
        case .oppo, .vivo: 0.82
        case .sony, .honor: 0.80
        case .fujifilm, .samsung, .nokia: 0.78
        case .panasonic: 0.72
        case .nikon: 1.0
        }
    }
}

struct PhotoFrameBrandIdentity: Equatable, Sendable {
    let brand: PhotoFrameBrand?
    let remainingModel: String
    var usesVectorLogo: Bool { brand != nil }

    /// The text fallback used when the platform cannot draw the Android vector
    /// asset. Keep the model suffix visible so the identity remains complete.
    var displayText: String {
        guard let brand else { return remainingModel }
        return [brand.rawValue.uppercased(), remainingModel].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

func photoFrameBrandIdentity(make: String?, model: String?) -> PhotoFrameBrandIdentity {
    let full = [make, model].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }.joined(separator: " ")
    guard let brand = PhotoFrameBrand.resolve(full) else { return PhotoFrameBrandIdentity(brand: nil, remainingModel: full) }
    let upper = full.uppercased()
    let prefix = brand == .nikon && upper.hasPrefix("NIKON CORPORATION") ? "NIKON CORPORATION"
        : brand == .nikon ? "NIKON" : brand.rawValue.uppercased()
    return PhotoFrameBrandIdentity(brand: brand, remainingModel: String(full.dropFirst(min(prefix.count, full.count))).trimmingCharacters(in: .whitespacesAndNewlines))
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
