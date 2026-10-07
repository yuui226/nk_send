import Foundation

/// Android RemoteCameraTools.kt and RemoteCameraToolPanel.kt. Query actual
/// descriptors, never infer support from advertised property lists.
enum RemoteCameraTool: String, Identifiable, Sendable {
    case whiteBalance, focusArea
    var id: Self { self }

    func properties(movie: Bool) -> [RemoteProperty] {
        switch self {
        case .whiteBalance: movie ? [.movieWhiteBalance, .movieWhiteBalanceAlternate] : [.whiteBalance]
        case .focusArea: movie ? [.movieFocusArea] : [.focusArea, .liveViewFocusArea]
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
        var body = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
        if body.hasPrefix("NIKON") { body = String(body.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
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

    func hasTapMarker(_ descriptor: RemotePropertyDescriptor, value: UInt64) -> Bool {
        self == .focusArea && [.focusArea, .liveViewFocusArea, .movieFocusArea].contains(descriptor.property)
            && [0x8011, 0x8020, 0x8021].contains(value)
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
        "pinpoint", "spot", "single", "normal", "dynamic", "dynamic_9", "dynamic_21", "dynamic_25",
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
            if readable == nil { readable = descriptor }
            if descriptor.writable && !descriptor.values.isEmpty { return descriptor }
        }
        return readable
    }
}
