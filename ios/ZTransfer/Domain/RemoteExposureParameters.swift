import Foundation

/// Nikon remote-control property codes and value rules. Keep these values in one place so the
/// iOS monitor can follow the Android RemoteLab protocol without inventing a second mapping.
enum RemoteProperty: UInt32, CaseIterable, Sendable {
    case batteryLevel = 0x5001
    case focusMode = 0x500A
    case nikonAFMode = 0xD161
    case angleLevel = 0xD067
    case fNumber = 0x5007
    case exposureProgram = 0x500E
    case iso = 0x500F
    case exposureCompensation = 0x5010
    case exposureTimeStandard = 0x500D
    case nikonExposureCompensation = 0xD058
    case nikonAutoISO = 0xD054
    case nikonShutter = 0xD100
    case movieAutoISO = 0xD0AD
    case nikonISOEx = 0xD0B4
    case nikonISOControlSensitivity = 0xD0B5
    case nikonAutoISOAlternate = 0xD16A
    case movieShutter = 0xD1A8
    case movieFNumber = 0xD1A9
    case movieISO = 0xD1AA
    case movieExposureCompensation = 0xD1AB
    case liveViewSelector = 0xD1A6
    case liveViewImageSize = 0xD1AC
    case applicationMode = 0xD1F0
}

enum RemoteExposureField: Hashable, Identifiable, Sendable {
    case exposureCompensation, iso, aperture, shutter
    var id: Self { self }
}

struct RemotePropertyDescriptor: Equatable, Sendable {
    let property: RemoteProperty
    let dataType: UInt16
    let writable: Bool
    var current: UInt64
    let values: [UInt64]

    /// RemoteLab.rcIsBinaryToggle: Nikon may omit the enum for a writable byte switch.
    var isBinaryToggle: Bool {
        writable && ((values.contains(0) && values.contains { $0 != 0 }) ||
            (values.isEmpty && [0x0001, 0x0002].contains(dataType) && current <= 1))
    }

    /// Invalid/unknown values are not percentages (RemoteLab.rcBatteryPercentage).
    var batteryPercentage: Int? {
        guard property == .batteryLevel, dataType == 0x0002, current <= 100 else { return nil }
        return Int(current)
    }

    /// RemoteLab.rcAngleLevelRoll, including integer-degree legacy cameras and wraparound.
    var angleLevelRoll: Double? {
        let degrees: Double
        switch dataType {
        case 0x0005, 0x0006: degrees = Double(Int64(bitPattern: current)) / 65536
        case 0x0001...0x0004: degrees = Double(Int64(bitPattern: current))
        default: return nil
        }
        var roll = degrees.truncatingRemainder(dividingBy: 360)
        if roll > 180 { roll -= 360 }
        if roll <= -180 { roll += 360 }
        return roll
    }

    init(property: RemoteProperty, dataType: UInt16 = 0x0006, writable: Bool,
         current: UInt64, values: [UInt64]) {
        self.property = property
        self.dataType = dataType
        self.writable = writable
        self.current = current
        self.values = values
    }
}

enum RemoteExposureParameters {
    static let photoProperties: [RemoteProperty] = [.exposureCompensation, .iso, .fNumber, .nikonShutter]
    static let movieProperties: [RemoteProperty] = [.movieExposureCompensation, .movieISO, .movieFNumber, .movieShutter]

    static func autoISOProperties(movie: Bool) -> [RemoteProperty] {
        movie ? [.movieAutoISO, .nikonAutoISOAlternate, .nikonAutoISO]
              : [.nikonAutoISO, .nikonAutoISOAlternate]
    }

    static func compatibleProperties(for field: RemoteExposureField, movie: Bool = false) -> [RemoteProperty] {
        if movie {
            return switch field {
            case .exposureCompensation: [.movieExposureCompensation]
            case .iso: [.movieISO]
            case .aperture: [.movieFNumber]
            case .shutter: [.movieShutter]
            }
        }
        return switch field {
        case .exposureCompensation: [.exposureCompensation, .nikonExposureCompensation]
        case .iso: [.iso, .nikonISOEx]
        case .aperture: [.fNumber]
        case .shutter: [.nikonShutter, .exposureTimeStandard]
        }
    }

    /// Direction used by Android's `downStepSign`: dragging downward always
    /// increases the physical value, regardless of enum ordering.
    static func downStepSign(for property: RemoteProperty, values: [UInt64]) -> Int {
        guard values.count > 1 else { return -1 }
        func metric(_ raw: UInt64) -> Double {
            switch property {
            case .nikonShutter, .movieShutter:
                switch raw {
                case 0xFFFF_FFFF, 0xFFFF_FFFE, 0xFFFF_FFFD: return 0
                default:
                    let numerator = Double((raw >> 16) & 0xFFFF)
                    let denominator = Double(raw & 0xFFFF)
                    return numerator > 0 ? denominator / numerator : 0
                }
            case .fNumber, .movieFNumber: return -Double(raw)
            case .iso, .nikonISOEx, .nikonISOControlSensitivity, .movieISO: return Double(raw)
            case .exposureCompensation, .nikonExposureCompensation, .movieExposureCompensation: return Double(Int64(bitPattern: raw))
            default: return Double(raw)
            }
        }
        return metric(values.last!) > metric(values.first!) ? 1 : -1
    }

    /// Prefer a writable descriptor with a value domain; retain the first readable descriptor as
    /// a display fallback when a camera exposes the property but refuses writes.
    static func selectWritable(_ descriptors: [RemotePropertyDescriptor]) -> RemotePropertyDescriptor? {
        descriptors.first(where: { $0.writable && !$0.values.isEmpty }) ?? descriptors.first
    }

    static func canonical(_ property: RemoteProperty) -> RemoteProperty {
        switch property {
        case .nikonExposureCompensation: return .exposureCompensation
        case .nikonISOEx: return .iso
        case .exposureTimeStandard: return .nikonShutter
        default: return property
        }
    }

    static func format(_ property: RemoteProperty, raw: UInt64) -> String {
        switch property {
        case .batteryLevel: return "\(raw)%"
        case .fNumber, .movieFNumber: return String(format: "f/%.1f", Double(raw) / 100)
        case .nikonShutter, .movieShutter:
            switch raw {
            case 0xFFFFFFFF: return "Bulb"
            case 0xFFFFFFFE: return "x200"
            case 0xFFFFFFFD: return "Time"
            default:
                let numerator = (raw >> 16) & 0xFFFF
                let denominator = raw & 0xFFFF
                guard numerator > 0, denominator > 0 else { return String(raw) }
                if numerator == 1 { return "1/\(denominator)s" }
                if numerator % denominator == 0 { return "\(numerator / denominator)s" }
                if denominator % numerator == 0 { return "1/\(denominator / numerator)s" }
                return String(format: "%.1fs", Double(numerator) / Double(denominator))
            }
        case .exposureTimeStandard: return String(format: "%.4fs", Double(raw) / 10000)
        case .exposureCompensation, .nikonExposureCompensation, .movieExposureCompensation:
            return String(format: "%+.1fEV", Double(Int64(bitPattern: raw)) / 1000)
        case .iso, .nikonISOEx, .nikonISOControlSensitivity, .movieISO: return "ISO\(raw)"
        case .nikonAutoISO, .nikonAutoISOAlternate, .movieAutoISO: return raw == 0 ? "Off" : "On"
        case .exposureProgram:
            switch raw { case 1: return "M"; case 2: return "P"; case 3: return "A"; case 4: return "S"; case 0x8010: return "AUTO"; default: return String(format: "0x%llx", raw) }
        case .liveViewSelector: return raw == 0 ? "照片" : "录像"
        case .focusMode:
            return [1: "MF", 2: "AF", 3: "AF Macro", 0x8010: "AF-S", 0x8011: "AF-C", 0x8012: "AF-A", 0x8013: "AF-F"][raw]
                ?? String(format: "0x%llx", raw)
        case .nikonAFMode:
            return [0: "AF-S", 1: "AF-C", 2: "AF-A"][raw] ?? String(format: "0x%llx", raw)
        case .angleLevel: return String(format: "%.1f°", Double(Int64(bitPattern: raw)) / 65536)
        case .liveViewImageSize, .applicationMode: return String(raw)
        }
    }
}

struct RemotePropertySetResult: Sendable {
    let responseCode: UInt16
    let actual: RemotePropertyDescriptor?
    let confirmed: Bool
}

extension RemoteCameraControlling {
    /// RemoteLab.rcSetValueVerified. Superseding a value stops at transaction
    /// boundaries so cancelling a UI edit cannot corrupt the shared PTP stream.
    func setRemotePropertyVerified(_ descriptor: RemotePropertyDescriptor, value: UInt64,
                                  isCurrent: @Sendable () async -> Bool = { true }) async throws -> RemotePropertySetResult {
        func checkCurrent() async throws {
            guard await isCurrent() else { throw CancellationError() }
        }
        func write() async throws -> UInt16 {
            try await checkCurrent()
            do { try await setRemoteProperty(descriptor, value: value); return PTPConstants.responseOK }
            catch PTPSessionError.responseCode(let code) { return code }
        }
        var response = try await write()
        for wait in [120, 240] where response == PTPConstants.deviceBusy {
            try await Task.sleep(for: .milliseconds(wait))
            response = try await write()
        }
        guard response == PTPConstants.responseOK else {
            return .init(responseCode: response, actual: nil, confirmed: false)
        }
        var actual: RemotePropertyDescriptor?
        func readBack(_ waits: [Int]) async throws -> Bool {
            for wait in waits {
                try await Task.sleep(for: .milliseconds(wait))
                try await checkCurrent()
                do {
                    if let next = try await refreshRemoteProperty(descriptor) {
                        actual = next
                        if next.current == value { return true }
                    }
                } catch PTPSessionError.responseCode(_) { }
            }
            return false
        }
        if try await readBack([40, 90, 160]) {
            return .init(responseCode: response, actual: actual, confirmed: true)
        }
        if actual != nil {
            try await Task.sleep(for: .milliseconds(100))
            response = try await write()
            if response == PTPConstants.responseOK, try await readBack([70, 150]) {
                return .init(responseCode: response, actual: actual, confirmed: true)
            }
        }
        return .init(responseCode: response, actual: actual, confirmed: false)
    }
}
