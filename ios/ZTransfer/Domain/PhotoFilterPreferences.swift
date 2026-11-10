import Foundation

/// Android PhotoFilterIdentity / PhotoFilterAdjustments / intensity codec.
/// Rendering IDs include the converter version; editor memory keys do not.
enum PhotoFilterPreferences {
    static let adjustmentsKey = "photo_filter_adjustments_v1"
    static let appliedAdjustmentsKey = "photo_filter_applied_adjustments_v1"
    static let builtInKeys = Set(Np3FilterCatalog.presets.map(\.catalogKey))

    static func catalogKey(_ id: String) -> String? {
        Np3FilterCatalog.preset(id: id)?.catalogKey ?? PhotoNp3RecipeKind.sourceDigest(id).map { "np3:" + $0 }
    }
    static func isCustomKey(_ key: String) -> Bool {
        key.hasPrefix("np3:") && PhotoNp3RecipeKind.isDigest(key.dropFirst(4))
    }
    private static func validShape(_ key: String) -> Bool {
        if isCustomKey(key) { return true }
        return (1...128).contains(key.utf8.count) && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
    static func accepts(_ key: String, validKeys: Set<String> = builtInKeys) -> Bool {
        validShape(key) && (validKeys.contains(key) || isCustomKey(key))
    }
    static func decodeIntensities(_ text: String?, validKeys: Set<String> = builtInKeys) -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in (text ?? "").split(separator: ";") {
            let fields = entry.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2, let value = Int32(fields[1]) else { continue }
            let key = String(fields[0])
            guard accepts(key, validKeys: validKeys), result[key] == nil else { continue }
            result[key] = Np3FilterEngine.normalizeIntensity(Int(value))
        }
        return result
    }
    static func encodeIntensities(_ values: [String: Int]) -> String {
        values.keys.filter(validShape).sorted().map { "\($0),\(Np3FilterEngine.normalizeIntensity(values[$0]!))" }.joined(separator: ";")
    }
    static func decodeAdjustments(_ text: String?, validKeys: Set<String> = builtInKeys) -> [String: LUTAdjustments] {
        var result: [String: LUTAdjustments] = [:]
        for entry in (text ?? "").split(separator: ";") {
            let fields = entry.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 5 else { continue }
            let key = String(fields[0])
            guard accepts(key, validKeys: validKeys), result[key] == nil else { continue }
            let values = fields.dropFirst().compactMap { Int32($0).map(Int.init) }
            guard values.count == 4 else { continue }
            result[key] = LUTAdjustments(contrast: values[0], saturation: values[1], highlights: values[2], shadows: values[3]).normalized
        }
        return result
    }
    static func encodeAdjustments(_ values: [String: LUTAdjustments]) -> String {
        values.keys.filter(validShape).sorted().map { key in
            let value = values[key]!.normalized
            return "\(key),\(value.contrast),\(value.saturation),\(value.highlights),\(value.shadows)"
        }.joined(separator: ";")
    }
    static func normalizeAdjustments(_ values: [String: LUTAdjustments]) -> [String: LUTAdjustments] {
        values.filter { accepts($0.key) }.mapValues(\.normalized)
    }
}
