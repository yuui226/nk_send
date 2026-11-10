import Foundation
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

