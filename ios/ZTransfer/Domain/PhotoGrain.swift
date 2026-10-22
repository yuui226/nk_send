import Foundation
import CoreFoundation

// Android PhotoGrainSettings/PhotoGrainPreferences (1f804ab8). Settings are a
// render recipe; remembered wheel values belong to the editor's own scope.
enum PhotoGrainStyle: String, Codable, CaseIterable, Sendable {
    case fine, medium, coarse
    var nativeIndex: Int32 { switch self { case .fine: 0; case .medium: 1; case .coarse: 2 } }
    var defaultIntensity: Int { switch self { case .fine: 50; case .medium: 40; case .coarse: 30 } }
    var localizationKey: String { "photo_grain_\(rawValue)" }
}

struct PhotoGrainSettings: Codable, Equatable, Sendable {
    var intensityPercent = 50
    var enabled = false
    var style: PhotoGrainStyle = .fine
    init(intensityPercent: Int = 50, enabled: Bool = false, style: PhotoGrainStyle = .fine) {
        self.intensityPercent = intensityPercent; self.enabled = enabled; self.style = style
    }
    private enum CodingKeys: String, CodingKey { case intensityPercent, enabled, style }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = PhotoGrainStyle(rawValue: (try? values.decode(String.self, forKey: .style)) ?? "") ?? .fine
        intensityPercent = min(100, max(0, (try? values.decode(Int.self, forKey: .intensityPercent)) ?? style.defaultIntensity))
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? false
    }
    static let off = Self()
    var normalizedIntensity: Int { min(100, max(0, intensityPercent)) }
    var isEnabled: Bool { enabled && normalizedIntensity > 0 }
    var normalized: Self { Self(intensityPercent: normalizedIntensity, enabled: enabled, style: style) }

    func selecting(_ next: PhotoGrainStyle?, memories: [String: Int]) -> Self {
        guard let next else {
            var result = normalized
            result.enabled = false
            return result
        }
        return Self(intensityPercent: next == style ? normalizedIntensity
                    : min(100, max(0, memories[next.rawValue] ?? next.defaultIntensity)), enabled: true, style: next)
    }

    func changingIntensity(_ intensity: Int, for capturedStyle: PhotoGrainStyle) -> Self {
        guard enabled, style == capturedStyle else { return self }
        return Self(intensityPercent: min(100, max(0, intensity)), enabled: true, style: style)
    }
}

func normalizedPhotoGrainIntensities(_ values: [String: Int]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: PhotoGrainStyle.allCases.map {
        ($0.rawValue, min(100, max(0, values[$0.rawValue] ?? $0.defaultIntensity)))
    })
}

/// Stable FNV-1a, including extension, independent of staging directory/case.
func photoGrainSeed(_ sourceName: String) -> Int32 {
    let name = sourceName.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    let leaf = name.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    let hash = leaf.lowercased().utf8.reduce(UInt32(0x811c9dc5)) { ($0 ^ UInt32($1)) &* 0x01000193 }
    return Int32(bitPattern: hash)
}

enum PhotoGrainPreferences {
    struct State: Equatable {
        var settings: PhotoGrainSettings
        var intensities: [String: Int]
    }

    static func restore(_ defaults: UserDefaults, prefix: String, allowEnabled: Bool = true) -> State? {
        let keys = ["style", "enabled", "intensity"] + PhotoGrainStyle.allCases.map { "intensity_\($0.rawValue)" }
        guard keys.contains(where: { defaults.object(forKey: "\(prefix)_\($0)") != nil }) else { return nil }
        let style = PhotoGrainStyle(rawValue: defaults.string(forKey: "\(prefix)_style") ?? "") ?? .fine
        let legacy = integer(defaults.object(forKey: "\(prefix)_intensity"))
        let memories = Dictionary(uniqueKeysWithValues: PhotoGrainStyle.allCases.map { item in
            (item.rawValue, integer(defaults.object(forKey: "\(prefix)_intensity_\(item.rawValue)"))
                ?? (item == .fine ? legacy : nil) ?? item.defaultIntensity)
        })
        let hasNewKeys = (["style"] + PhotoGrainStyle.allCases.map { "intensity_\($0.rawValue)" })
            .contains { defaults.object(forKey: "\(prefix)_\($0)") != nil }
        let storedEnabled = defaults.object(forKey: "\(prefix)_enabled")
        let enabled: Bool
        if let number = storedEnabled as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            enabled = number.boolValue
        } else { enabled = storedEnabled == nil && !hasNewKeys && (legacy ?? 0) > 0 }
        return State(settings: .init(intensityPercent: memories[style.rawValue]!, enabled: enabled && allowEnabled, style: style), intensities: memories)
    }

    /// Does not overwrite newer detent memories with the still-uncommitted
    /// camera recipe. Both callers explicitly capture the current wheel value.
    static func persist(_ settings: PhotoGrainSettings, intensities: [String: Int], defaults: UserDefaults, prefix: String) {
        let memories = normalizedPhotoGrainIntensities(intensities)
        defaults.set(settings.style.rawValue, forKey: "\(prefix)_style")
        defaults.set(settings.enabled, forKey: "\(prefix)_enabled")
        for style in PhotoGrainStyle.allCases { defaults.set(memories[style.rawValue]!, forKey: "\(prefix)_intensity_\(style.rawValue)") }
        defaults.set(memories["fine"]!, forKey: "\(prefix)_intensity")
    }

    private static func integer(_ value: Any?) -> Int? {
        if let string = value as? String, let number = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Int(min(100, max(0, number)))
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int(min(100, max(0, number.int64Value)))
    }
}
