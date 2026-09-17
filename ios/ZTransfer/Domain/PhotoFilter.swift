import Foundation

struct PhotoDateRange: Equatable, Sendable, Codable {
    let start: String
    let end: String
    func contains(_ captureDate: String?) -> Bool {
        guard let date = captureDate?.prefix(8), date.count == 8 else { return false }
        let key = String(date)
        guard validPhotoCaptureDay(key) != nil,
              validPhotoCaptureDay(start) != nil,
              validPhotoCaptureDay(end) != nil else { return false }
        return key >= start && key <= end
    }
}

func validPhotoCaptureDay(_ value: String?) -> String? {
    guard let value, value.count >= 8 else { return nil }
    let dayValue = String(value.prefix(8))
    guard dayValue.allSatisfy(\.isNumber),
          let year = Int(dayValue.prefix(4)),
          let month = Int(dayValue.dropFirst(4).prefix(2)),
          let day = Int(dayValue.dropFirst(6).prefix(2)) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
        return nil
    }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    return resolved.year == year && resolved.month == month && resolved.day == day ? dayValue : nil
}

func restoredPhotoDateRange(start: String?, end: String?) -> PhotoDateRange? {
    func parseISO(_ value: String?) -> String? {
        guard let value,
              value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return validPhotoCaptureDay(value.replacingOccurrences(of: "-", with: ""))
    }
    guard let first = parseISO(start), let second = parseISO(end) else { return nil }
    return first <= second
        ? PhotoDateRange(start: first, end: second)
        : PhotoDateRange(start: second, end: first)
}

struct PhotoFilterState: Equatable, Sendable, Codable {
    var extensions: Set<String>? = nil
    var protectedOnly = false
    var burstOnly = false
    var untransferredOnly = false
    /// Logical physical slot (1/2), not the camera's opaque PTP StorageID.
    /// Android intentionally keeps this selection process-local.
    var storageSlot: UInt32?
    var dateRange: PhotoDateRange?

    var isActive: Bool {
        extensions != nil || protectedOnly || burstOnly || untransferredOnly ||
            storageSlot != nil || dateRange != nil
    }
}

enum PhotoFilter {
    static func apply(_ files: [CameraFile], state: PhotoFilterState,
                      transferredIDs: Set<UInt32> = [],
                      storageIDsBySlot: [UInt32: Set<UInt32>] = [:]) -> [CameraFile] {
        let burstIDs: Set<UInt32>? = state.burstOnly
            ? Set(PhotoCatalogGrouping.bursts(in: files).flatMap { $0.files.map(\.id) })
            : nil
        return files.filter { file in
            let ext = file.fileExtension.lowercased()
            guard state.extensions == nil || state.extensions!.contains(ext) else { return false }
            guard !state.protectedOnly || file.isProtected else { return false }
            guard !state.burstOnly || burstIDs?.contains(file.id) == true else { return false }
            guard !state.untransferredOnly || !transferredIDs.contains(file.id) else { return false }
            if let slot = state.storageSlot {
                guard let storageIDs = storageIDsBySlot[slot],
                      !file.storageIDs.isDisjoint(with: storageIDs) else { return false }
            }
            guard state.dateRange?.contains(file.captureDate) ?? true else { return false }
            return true
        }
    }
}

/// Queue completions are the only transferred items that leave the active
/// "untransferred" grid with an animation. Existing files discovered by a
/// directory scan remain an immediate filter result.
func newlyExitingTransferredFileIDs(
    previous: Set<UInt32>,
    current: Set<UInt32>,
    queueItems: [TransferQueueItem],
    untransferredOnly: Bool
) -> Set<UInt32> {
    guard untransferredOnly else { return [] }
    let candidates = Set(queueItems.compactMap { item -> UInt32? in
        switch item.status {
        case .waiting, .transferring, .completed: return item.file.id
        case .failed, .cancelled: return nil
        }
    })
    return current.subtracting(previous).intersection(candidates)
}

/// PTP StorageID uses its high 16 bits for the physical store and low 16 bits
/// for a logical partition. Nikon also reports a few non-standard IDs, which
/// Android assigns to the first free physical slot in stable sorted order.
func photoStorageIDsBySlot(_ storageIDs: [UInt32]) -> [UInt32: Set<UInt32>] {
    var result: [UInt32: Set<UInt32>] = [:]
    var unassigned: [UInt32: Set<UInt32>] = [:]
    for storageID in Set(storageIDs).sorted() {
        let physical = (storageID >> 16) & 0xFFFF
        let logical = storageID & 0xFFFF
        let slot: UInt32? = (1...2).contains(physical) ? physical :
            (physical == 0 && (1...2).contains(logical) ? logical : nil)
        if let slot { result[slot, default: []].insert(storageID) }
        else { unassigned[physical == 0 ? storageID : physical, default: []].insert(storageID) }
    }
    for key in unassigned.keys.sorted() {
        guard let slot = ([UInt32(1), 2].first { result[$0] == nil }) else { break }
        result[slot] = unassigned[key]
    }
    return result
}

func normalizedPhotoStorageSlot(_ selected: UInt32?, available: [UInt32], scanComplete: Bool) -> UInt32? {
    guard let selected, scanComplete else { return selected }
    return available.count > 1 && available.contains(selected) ? selected : nil
}

/// A nil filter means every available card is selected. With Nikon's two-slot
/// model, tapping one selected chip deselects that card and therefore leaves
/// the other slot as the single active filter.
func isPhotoStorageSlotSelected(_ selected: UInt32?, slot: UInt32) -> Bool {
    selected == nil || selected == slot
}

func toggledPhotoStorageSlot(_ selected: UInt32?, toggled: UInt32,
                             available: [UInt32]) -> UInt32? {
    let slots = Array(Set(available)).sorted()
    guard slots.contains(toggled) else { return selected }
    if selected == nil { return slots.first { $0 != toggled } }
    if selected == toggled { return selected }
    return nil
}

enum PhotoFilterPersistence {
    private static let extensionsKey = "filter_exts"
    private static let protectedKey = "filter_protected"
    private static let burstKey = "filter_burst"
    private static let untransferredKey = "filter_untransferred"
    private static let startKey = "filter_date_start"
    private static let endKey = "filter_date_end"

    static func load(from defaults: UserDefaults = .standard) -> PhotoFilterState {
        let extensions = defaults.stringArray(forKey: extensionsKey).map { Set($0.map { $0.lowercased() }) }
        return PhotoFilterState(extensions: extensions?.isEmpty == false ? extensions : nil,
                                protectedOnly: defaults.bool(forKey: protectedKey),
                                burstOnly: defaults.bool(forKey: burstKey),
                                untransferredOnly: defaults.bool(forKey: untransferredKey),
                                storageSlot: nil,
                                dateRange: restoredPhotoDateRange(
                                    start: defaults.string(forKey: startKey),
                                    end: defaults.string(forKey: endKey)
                                ))
    }

    static func save(_ state: PhotoFilterState, to defaults: UserDefaults = .standard) {
        if let extensions = state.extensions { defaults.set(Array(extensions).sorted(), forKey: extensionsKey) }
        else { defaults.removeObject(forKey: extensionsKey) }
        set(state.protectedOnly, key: protectedKey, defaults: defaults)
        set(state.burstOnly, key: burstKey, defaults: defaults)
        set(state.untransferredOnly, key: untransferredKey, defaults: defaults)
        // Slot selection belongs to the current camera process only.
        defaults.removeObject(forKey: "filter_storage_slot")
        if let range = state.dateRange {
            defaults.set(hyphenated(range.start), forKey: startKey)
            defaults.set(hyphenated(range.end), forKey: endKey)
        } else {
            defaults.removeObject(forKey: startKey)
            defaults.removeObject(forKey: endKey)
        }
    }

    private static func set(_ enabled: Bool, key: String, defaults: UserDefaults) {
        if enabled { defaults.set(true, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private static func hyphenated(_ value: String) -> String {
        guard value.count == 8 else { return value }
        return "\(value.prefix(4))-\(value.dropFirst(4).prefix(2))-\(value.suffix(2))"
    }
}
