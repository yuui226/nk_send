import Foundation

/// Android GlassButton baseElevation/elevation. This controls material height
/// and press collapse only. The caller's legacy iOS shadow projection remains
/// an unverified T02 gap, not an approved substitute for Android's projection.
enum ZTransferButtonElevation {
    static func base(skin: ZTransferButtonSkin, active: Bool, panel: Bool) -> CGFloat {
        base(skin: skin, activeProgress: active ? 1 : 0, panel: panel)
    }

    static func base(skin: ZTransferButtonSkin, activeProgress: CGFloat, panel: Bool) -> CGFloat {
        if panel { return 0 }
        let active = min(max(activeProgress, 0), 1)
        switch skin {
        case .titanium: return 7 + 2 * active
        case .wood: return 8 + 2 * active
        case .cameraControls: return 9 + 2 * active
        case .frostedGlass, .liquidGlass: return 4 + 3 * active
        }
    }

    static func value(skin: ZTransferButtonSkin, active: Bool, panel: Bool,
                      override: CGFloat?, pressProgress: CGFloat) -> CGFloat {
        value(skin: skin, activeProgress: active ? 1 : 0, panel: panel,
              override: override, pressProgress: pressProgress)
    }

    static func value(skin: ZTransferButtonSkin, activeProgress: CGFloat, panel: Bool,
                      override: CGFloat?, pressProgress: CGFloat) -> CGFloat {
        // Final Android frosted branch has no elevation, even with an override.
        guard skin != .frostedGlass else { return 0 }
        let elevation = override ?? base(skin: skin, activeProgress: activeProgress, panel: panel)
        if panel { return elevation }
        let press = min(1, max(0, pressProgress))
        switch skin {
        case .cameraControls: return elevation * (1 - 0.82 * press)
        case .titanium, .wood: return elevation * (1 - 0.66 * press)
        case .frostedGlass, .liquidGlass: return elevation
        }
    }
}
