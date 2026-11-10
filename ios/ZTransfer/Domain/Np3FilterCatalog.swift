import Foundation

/// Legacy metadata shape retained for decoding old preferences and callers.
struct Np3FilterPreset: Equatable, Identifiable, Sendable {
    let id: String
    let catalogKey: String
    let legacyID: String
    let name: String
    let fallbackName: String
    let parameters: Np3FilterParameters
}

/// No filters ship with iOS. The user approved removal on 2026-11-05 because
/// redistribution rights were unknown. Keep a deliberately empty resolver so
/// old IDs are rejected by existing preference normalization. Imported NP3s
/// carry their own validated recipes and never depend on this catalog.
enum Np3FilterCatalog {
    static let presets: [Np3FilterPreset] = []
    static func preset(id: String) -> Np3FilterPreset? { nil }
}
