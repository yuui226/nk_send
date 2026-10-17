import Foundation

/// Display-only monitor options copied from Android RemoteScreen preferences.
enum RemoteDisplayOptions {
    static let desqueezeValues: [Double] = [1, 1.33, 1.5, 1.8, 2]

    static func normalizedDesqueeze(_ value: Double) -> Double {
        // RemoteToolPreferences rejects an invalid stored multiplier rather
        // than clamping it to a different active lens correction.
        guard value.isFinite, (1...2).contains(value) else { return 1 }
        return value
    }

    static func nextDesqueeze(after value: Double) -> Double {
        let normalized = normalizedDesqueeze(value)
        // RemoteScreen advances from the nearest preset, including values
        // restored from an older/custom preference. Equal distances keep the
        // first preset, matching Kotlin minByOrNull.
        var index = 0
        for candidate in desqueezeValues.indices.dropFirst() {
            if abs(desqueezeValues[candidate] - normalized) < abs(desqueezeValues[index] - normalized) {
                index = candidate
            }
        }
        return desqueezeValues[(index + 1) % desqueezeValues.count]
    }

    static func label(for value: Double) -> String {
        abs(value - 1.33) < 0.01 ? "1.3" : String(format: "%.1f", value)
    }
}

/// Geometry tokens for Android's `CameraMonitorDisp` readout. Keeping these
/// values outside the SwiftUI body makes the top-row reservation and bottom
/// cell width testable without rendering a live camera frame.
enum RemoteDispLayout {
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 10
    static let standbyTrailingReservation: CGFloat = 100
    static let bottomCellSpacing: CGFloat = 16
    static let bottomMaxWidth: CGFloat = 400
    static let informationInset: CGFloat = 32

    static func topTextWidth(containerWidth: CGFloat) -> CGFloat {
        max(0, containerWidth - horizontalInset * 2 - standbyTrailingReservation)
    }
}

/// Wire-only DISP values shared by the monitor overlay and its diagnostics.
///
/// The Android implementation deliberately rejects values it cannot prove: a
/// UINT8 property is not the packed movie-format property used by Z30, and an
/// invalid storage tuple must never be presented as available capacity. Keep
/// these decoders free of UI state so protocol replay tests can exercise the
/// same boundaries before the polling/UI block is connected.
enum RemoteMonitorTelemetry {
    /// Camera DISP top-row order is stable across transports: each storage
    /// card, one combined movie format/remaining-time group, then battery.
    static func cameraTopRowItems(storage: [String], movie: Bool,
                                  movieFormat: String?, remaining: String?,
                                  batteryPercent: Int?) -> [String] {
        var items = storage
        let movieGroup = [movieFormat, remaining].compactMap { $0 }.joined(separator: " ")
        if movie, !movieGroup.isEmpty { items.append(movieGroup) }
        if let batteryPercent { items.append("\(batteryPercent)%") }
        return items
    }

    static func cameraShowsStandby(movie: Bool, recording: Bool) -> Bool {
        movie && !recording
    }

    /// D0A0 UINT64: flags (low 16), frame rate, height, width (high 16).
    static func movieFormatLabel(dataType: UInt16, raw: UInt64) -> String? {
        guard dataType == 0x0008 else { return nil }
        let flags = raw & 0xFFFF
        let rate = (raw >> 16) & 0xFFFF
        let height = (raw >> 32) & 0xFFFF
        let width = (raw >> 48) & 0xFFFF
        guard flags == 0, (1...480).contains(rate) else { return nil }
        let resolution: String
        switch (width, height) {
        case (1920, 1080): resolution = "1080"
        case (3840, 2160): resolution = "4K"
        case (1280, 720): resolution = "720"
        default: return nil
        }
        return "\(resolution) \(rate)p"
    }

    /// Android's DISP formatting: hours are included only once the value
    /// reaches one hour, while minutes/seconds always remain two digits.
    static func remainingTimeLabel(seconds: Int64) -> String? {
        guard (0...86_400).contains(seconds) else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds / 60) % 60
        let remainder = seconds % 60
        func twoDigits(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }
        if hours > 0 { return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))" }
        return "\(twoDigits(minutes)):\(twoDigits(remainder))"
    }

    /// PTP GetStorageInfo's fixed fields are little-endian UINT64 values.
    /// Bytes before offset 6 are the dataset header/type fields. Return nil
    /// for truncated, unknown, negative, or inconsistent values.
    static func parseMonitorFreeBytes(_ data: Data) -> Int64? {
        guard data.count >= 26 else { return nil }
        func littleEndianInt64(_ offset: Int) -> Int64 {
            let bits = data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) {
                $0 | UInt64($1.element) << UInt64($1.offset * 8)
            }
            return Int64(bitPattern: bits)
        }
        let capacity = littleEndianInt64(6)
        let free = littleEndianInt64(14)
        guard capacity > 0, free >= 0, free <= capacity else { return nil }
        return free
    }
}
