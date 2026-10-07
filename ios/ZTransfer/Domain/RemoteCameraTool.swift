import Foundation

/// Android RemoteCameraTools.kt and RemoteCameraToolPanel.kt. Query actual
/// descriptors, never infer support from advertised property lists.
enum RemoteCameraTool: String, Identifiable, Sendable {
    case whiteBalance, focusArea, focusMode
    var id: Self { self }

    func properties(movie: Bool) -> [RemoteProperty] {
        switch self {
        case .whiteBalance: movie ? [.movieWhiteBalance, .movieWhiteBalanceAlternate] : [.whiteBalance]
        case .focusArea: movie ? [.movieFocusArea] : [.focusArea, .liveViewFocusArea]
        case .focusMode: [.focusMode, .stillFocusMode, .nikonAFMode]
        }
    }

    func labelResource(property: UInt32, value: UInt64, model: String? = nil,
                       dataType: UInt16? = nil) -> String? {
        if self == .whiteBalance {
            let names: [UInt64: String] = [
                1: "manual", 2: "auto", 3: "one_push", 4: "daylight", 5: "fluorescent",
                6: "incandescent", 7: "flash", 0x8015: "flash", 0x8010: "cloudy",
                0x8011: "shade", 0x8012: "kelvin", 0x8013: "preset", 0x8014: "off", 0x8016: "natural"
            ]
            return names[value].map { "remote_wb_" + $0 }
        }
        if self == .focusMode { return nil }
        var body = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
        if body.hasPrefix("NIKON") { body = String(body.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let isZ30 = body.replacingOccurrences(of: " ", with: "") == "Z30"
        if [0x501C, 0xD05D, 0xD1F8].contains(property), isZ30 {
            switch value {
            case 2: return "remote_af_dynamic_s"
            case 0x8013: return "remote_af_dynamic_m"
            case 0x8014: return "remote_af_dynamic_l"
            default: break
            }
        }
        if property == 0xD05D, dataType == 1 || dataType == 2 {
            return [0: "face_priority", 1: "wide", 2: "normal", 3: "subject_tracking", 4: "spot"][value]
                .map { "remote_af_" + $0 }
        }
        if property == 0x501C, ["D7100", "D850"].contains(body) {
            let specific: String?
            switch value {
            case 2: specific = body == "D7100" ? "dynamic_9" : "dynamic_25"
            case 0x8013: specific = body == "D7100" ? "dynamic_21" : "dynamic_72"
            case 0x8014: specific = body == "D7100" ? "dynamic_51" : "dynamic_153"
            case 0x8016: specific = body == "D850" ? "dynamic_9" : nil
            default: specific = nil
            }
            if let specific { return "remote_af_" + specific }
        }
        guard [0x501C, 0xD05D, 0xD1F8].contains(property) else { return nil }
        let name: String?
        switch value {
        case 2: name = property == 0x501C && body.hasPrefix("Z") ? "dynamic" : nil
        case 0x8012: name = body.hasPrefix("Z") || ["D7100", "D850"].contains(body) ? "tracking" : nil
        default:
            name = [0x8010: "single", 0x8011: "auto", 0x8015: "group", 0x8017: "pinpoint",
                    0x8018: "wide_s", 0x8019: "wide_l", 0x801A: "wide_people", 0x801B: "wide_animals",
                    0x8020: "auto_people", 0x8021: "auto_animals", 0x801E: "wide_c1", 0x801F: "wide_c2"][value]
        }
        return name.map { "remote_af_" + $0 }
    }

    func hasTapMarker(_ descriptor: RemotePropertyDescriptor, value: UInt64,
                      model: String? = nil) -> Bool {
        guard self == .focusArea,
              [.focusArea, .liveViewFocusArea, .movieFocusArea].contains(descriptor.property) else { return false }
        var candidate = descriptor
        candidate.current = value
        let path = rcTapFocusPath(candidate, model: model)
        return path == .tracking || path == .moveArea
    }

    func orderedValues(_ descriptor: RemotePropertyDescriptor, model: String?) -> [UInt64] {
        var seen = Set<UInt64>()
        let values = (descriptor.values + [descriptor.current]).filter { seen.insert($0).inserted }
        guard self == .focusArea else { return values }
        func rank(_ value: UInt64) -> Int {
            guard let resource = labelResource(property: descriptor.property.rawValue, value: value,
                                               model: model, dataType: descriptor.dataType) else { return .max }
            return Self.focusNameOrder.firstIndex(of: resource) ?? .max
        }
        return values.sorted {
            let first = rank($0), second = rank($1)
            return first == second ? Int64(bitPattern: $0) < Int64(bitPattern: $1) : first < second
        }
    }

    private static let focusNameOrder = [
        "pinpoint", "spot", "single", "normal", "dynamic", "dynamic_s", "dynamic_m", "dynamic_l",
        "dynamic_9", "dynamic_21", "dynamic_25",
        "dynamic_51", "dynamic_72", "dynamic_153", "wide", "wide_s", "wide_l", "wide_people",
        "wide_animals", "wide_c1", "wide_c2", "group", "auto", "auto_people", "auto_animals",
        "face_priority", "tracking", "subject_tracking"
    ].map { "remote_af_" + $0 }
}

extension RemoteCameraControlling {
    /// A negative property response is an unsupported candidate, not a reason
    /// to skip the fallback. Transport errors and cancellation still propagate.
    func remoteCameraTool(_ tool: RemoteCameraTool, movie: Bool) async throws -> RemotePropertyDescriptor? {
        var readable: RemotePropertyDescriptor?
        for property in tool.properties(movie: movie) {
            let descriptor: RemotePropertyDescriptor?
            do { descriptor = try await remoteProperty(property) }
            catch PTPSessionError.responseCode(_) { continue }
            guard let descriptor else { continue }
            if tool == .focusMode && !RemoteFocusMode.validDescriptor(descriptor) { continue }
            if readable == nil { readable = descriptor }
            if descriptor.writable && !descriptor.values.isEmpty { return descriptor }
        }
        return readable
    }
}

/// The two command paths exposed by Nikon's live-view protocol. UNKNOWN keeps
/// the legacy probe fallback for cameras whose AF-area encoding is not known;
/// UNSUPPORTED is reserved for a Z-family value that explicitly has no path.
enum RcTapFocusPath: Equatable, Sendable {
    case tracking, moveArea, unsupported, unknown
}

enum RemoteFocusMode {
    static let properties: [RemoteProperty] = [.focusMode, .stillFocusMode, .nikonAFMode]

    static func validDescriptor(_ descriptor: RemotePropertyDescriptor) -> Bool {
        switch descriptor.property {
        case .focusMode: descriptor.dataType == 0x0004
        case .stillFocusMode, .nikonAFMode: descriptor.dataType == 0x0002
        default: false
        }
    }

    static func label(property: RemoteProperty, value: UInt64) -> String? {
        switch property {
        case .focusMode:
            switch value {
            case 1: "MF"; case 2: "AF"; case 3: "AF Macro"
            case 0x8010: "AF-S"; case 0x8011: "AF-C"; case 0x8012: "AF-A"; case 0x8013: "AF-F"
            default: nil
            }
        case .stillFocusMode:
            switch value {
            case 0: "AF-S"; case 1: "AF-C"; case 2: "AF-F"
            case 3: "MF (fixed)"; case 4: "MF"; case 5: "AF-A"
            default: nil
            }
        case .nikonAFMode:
            switch value { case 0: "AF-S"; case 1: "AF-C"; case 2: "AF-A"; default: nil }
        default: nil
        }
    }

    static func manual(property: RemoteProperty, value: UInt64) -> Bool {
        (property == .focusMode && value == 1) ||
        (property == .stillFocusMode && (value == 3 || value == 4))
    }
}

func rcNormalizedToFocusCoordinate(_ normalized: Float, size: Int) -> Int {
    guard size > 1 else { return 0 }
    return Int((min(1, max(0, normalized)) * Float(size - 1)).rounded())
}

func rcTapFocusPath(_ descriptor: RemotePropertyDescriptor?, model: String?) -> RcTapFocusPath {
    guard let descriptor else { return .unknown }
    var body = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if body.hasPrefix("NIKON") { body = String(body.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
    let zFamily = body.hasPrefix("Z")
    let tracking: Set<UInt64> = [0x8011, 0x8012, 0x8020, 0x8021]
    let move: Set<UInt64> = [0x8010, 0x8015, 0x8017, 0x8018, 0x8019, 0x801A, 0x801B,
                             0x801E, 0x801F, 2, 0x8013, 0x8014]
    switch descriptor.property {
    case .focusArea, .movieFocusArea:
        if tracking.contains(descriptor.current) { return .tracking }
        if move.contains(descriptor.current) { return .moveArea }
        return zFamily ? .unsupported : .unknown
    case .liveViewFocusArea:
        if [0, 3].contains(descriptor.current) || tracking.contains(descriptor.current) { return .tracking }
        if [1, 2, 4].contains(descriptor.current) || move.contains(descriptor.current) { return .moveArea }
        return .unknown
    default: return .unknown
    }
}
