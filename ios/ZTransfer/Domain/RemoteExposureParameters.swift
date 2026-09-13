import Foundation

/// Nikon remote-control property codes and value rules. Keep these values in one place so the
/// iOS monitor can follow the Android RemoteLab protocol without inventing a second mapping.
enum RemoteProperty: UInt32, CaseIterable, Sendable {
    case focusMode = 0x500A
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
        case .focusMode: return raw == 1 ? "MF" : raw == 2 ? "AF" : String(format: "0x%llx", raw)
        case .angleLevel: return String(format: "%.1f°", Double(Int64(bitPattern: raw)) / 65536)
        }
    }
}
