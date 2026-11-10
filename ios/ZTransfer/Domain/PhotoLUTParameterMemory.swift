import CoreFoundation
import Foundation

/// PhotoLutParameterMemory.kt, adapted to the existing iOS dictionary storage.
/// Applied recipes and last-used detents are separate. Migration never writes
/// the old shared values, so an unopened second role sees its own legacy data.
struct PhotoLUTParameterMemory: Equatable {
    let intensity: Int
    let adjustments: LUTAdjustments
    static let fields = ["contrast", "saturation", "highlights", "shadows"]

    static func key(role: String, digest: String) -> String {
        precondition(role == "transfer" || role == "local")
        precondition(PhotoNp3RecipeKind.isDigest(digest))
        return "lut_adjustments_v2:\(role):\(digest)"
    }

    static func hasAdjustments(_ values: [String: Any]) -> Bool {
        fields.contains { values[$0] != nil }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.compare(NSNumber(value: Int32.min)) != .orderedAscending,
              number.compare(NSNumber(value: Int32.max)) != .orderedDescending else { return nil }
        return number.intValue
    }

    static func adjustments(_ fields: [String: Any]) -> LUTAdjustments {
        .init(contrast: integer(fields["contrast"]) ?? 0,
              saturation: integer(fields["saturation"]) ?? 0,
              highlights: integer(fields["highlights"]) ?? 0,
              shadows: integer(fields["shadows"]) ?? 0).normalized
    }

    static func resolve(values: [String: Any], role: String, digest: String,
                        source: String?, applied: [String: Any]?) -> Self {
        let key = key(role: role, digest: digest)
        let legacy = "lut_adjustments_v1:\(digest)"
        let current = applied?["digest"] as? String == digest
        let uri = source ?? (current ? applied?["source"] as? String : nil)
        let intensity: Any?
        if values[key + ":intensity"] != nil { intensity = values[key + ":intensity"] }
        else if current, applied?["intensity"] != nil { intensity = applied?["intensity"] }
        else if values[legacy + ":intensity"] != nil { intensity = values[legacy + ":intensity"] }
        else { intensity = uri.flatMap { values["strength:" + $0] } }
        let scoped = values[key] as? [String: Any] ?? [:]
        let saved = applied?["adjustments"] as? [String: Any] ?? [:]
        let fields = hasAdjustments(scoped) ? scoped
            : current && hasAdjustments(saved) ? saved : values[legacy] as? [String: Any] ?? [:]
        return .init(intensity: Np3FilterEngine.normalizeIntensity(integer(intensity) ?? 80),
                     adjustments: adjustments(fields))
    }
}
