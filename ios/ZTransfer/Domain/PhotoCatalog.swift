import Foundation

struct PhotoDaySection: Identifiable, Equatable, Sendable {
    let day: String
    let files: [CameraFile]
    var id: String { day }
}

struct BurstPhotoGroup: Identifiable, Equatable, Sendable {
    let id: String
    let files: [CameraFile]
}

struct PublishedPhotoIdentity: Hashable {
    let fileName: String
    let size: UInt64
    let captureDate: String?

    init(_ file: CameraFile) {
        fileName = file.fileName
        size = file.size
        captureDate = file.captureDate
    }
}

/// Dates whose visible logical photos disappeared in an authoritative camera
/// update. A surviving dual-card alias changes the session handle only and is
/// therefore deliberately excluded, matching Android's
/// `publishedCameraRemovalDates`.
func publishedCameraRemovalDays(
    previous: [CameraFile],
    current: [CameraFile]
) -> Set<String> {
    guard !previous.isEmpty else { return [] }
    let currentHandles = Set(current.map(\.id))
    let missing = previous.filter { !currentHandles.contains($0.id) }
    guard !missing.isEmpty else { return [] }
    let currentIdentities = Set(current.map(PublishedPhotoIdentity.init))
    return Set(missing.compactMap { file -> String? in
        guard !currentIdentities.contains(PublishedPhotoIdentity(file)) else { return nil }
        guard let captureDate = file.captureDate, captureDate.count >= 8 else {
            return PhotoCatalogGrouping.unknownDay
        }
        return String(captureDate.prefix(8))
    })
}

/// Keeps an expanded burst expanded when an authoritative camera deletion
/// changes the derived group id. Android matches successor groups by the
/// surviving logical file identity, not by the session-local object handle.
func reconciledExpandedBurstIDs(
    previousGroups: [BurstPhotoGroup],
    currentGroups: [BurstPhotoGroup],
    expandedIDs: Set<String>
) -> Set<String> {
    guard !expandedIDs.isEmpty, !currentGroups.isEmpty else { return [] }
    let currentIDs = Set(currentGroups.map(\.id))
    var reconciled = expandedIDs.intersection(currentIDs)
    guard previousGroups != currentGroups else { return reconciled }
    let previouslyExpanded = previousGroups.filter { expandedIDs.contains($0.id) }
    guard !previouslyExpanded.isEmpty else { return reconciled }

    var successorIDsByFile: [PublishedPhotoIdentity: Set<String>] = [:]
    for group in currentGroups {
        for file in group.files {
            successorIDsByFile[PublishedPhotoIdentity(file), default: []].insert(group.id)
        }
    }
    for group in previouslyExpanded {
        for file in group.files {
            reconciled.formUnion(successorIDsByFile[PublishedPhotoIdentity(file)] ?? [])
        }
    }
    return reconciled
}

/// Paging model used by the Android preview: a collapsed burst occupies one
/// page and its members are inserted only after the user explicitly expands it.
/// Keeping this separate from the flat camera catalog prevents preview paging
/// from silently changing list order or transfer selection.
enum PhotoPreviewEntry: Identifiable, Equatable, Sendable {
    case photo(CameraFile, burstID: String? = nil)
    case burst(BurstPhotoGroup)

    var id: String {
        switch self {
        case .photo(let file, _): return "photo_\(file.id)"
        case .burst(let group): return "preview_burst_\(group.id)"
        }
    }

    var file: CameraFile? {
        guard case .photo(let value, _) = self else { return nil }
        return value
    }

    var burstID: String? {
        guard case .photo(_, let value) = self else { return nil }
        return value
    }
}

/// Android bounds preview-only image state to the current page plus two pages
/// on either side. Collection pages do not own a high-resolution bitmap.
func retainedPhotoPreviewIDs(
    entries: [PhotoPreviewEntry],
    currentIndex: Int,
    radius: Int = 2
) -> Set<UInt32> {
    guard !entries.isEmpty, entries.indices.contains(currentIndex), radius >= 0 else { return [] }
    let lower = max(entries.startIndex, currentIndex - radius)
    let upper = min(entries.index(before: entries.endIndex), currentIndex + radius)
    return Set(entries[lower...upper].compactMap { $0.file?.id })
}

/// Neighbor FHD prefetch is deliberately serial and follows Android's order:
/// previous page first, then next page. Collection pages remain in the page
/// sequence but are ignored by the loader because they have no single file.
func neighboringPhotoPreviewIndices(entries: [PhotoPreviewEntry], currentIndex: Int) -> [Int] {
    guard entries.indices.contains(currentIndex) else { return [] }
    return [currentIndex - 1, currentIndex + 1].filter(entries.indices.contains)
}

/// Reproduces Android's initial preview item list.  Only the first member of a
/// recognized burst becomes the collection page; all other files retain their
/// catalog order and non-burst photos remain independent pages.
func collapsedPhotoPreviewEntries(files: [CameraFile], burstIDByFile: [UInt32: String]? = nil) -> [PhotoPreviewEntry] {
    let burstIDs = burstIDByFile ?? PhotoCatalogGrouping.bursts(in: files).reduce(into: [:]) { result, group in
        for file in group.files { result[file.id] = group.id }
    }
    let visibleGroups = Dictionary(grouping: files.compactMap { file -> (String, CameraFile)? in
        burstIDs[file.id].map { ($0, file) }
    }, by: \.0).mapValues { $0.map(\.1) }
    var collected = Set<String>()
    var result: [PhotoPreviewEntry] = []
    for file in files {
        guard let id = burstIDs[file.id], let members = visibleGroups[id], members.count >= 2 else {
            result.append(.photo(file, burstID: burstIDs[file.id])); continue
        }
        guard collected.insert(id).inserted else { continue }
        result.append(.burst(BurstPhotoGroup(id: id, files: members)))
    }
    return result
}

func expandPhotoPreviewBurst(_ entries: [PhotoPreviewEntry], at index: Int) -> [PhotoPreviewEntry] {
    guard entries.indices.contains(index), case .burst(let group) = entries[index] else { return entries }
    let members = group.files.map { PhotoPreviewEntry.photo($0, burstID: group.id) }
    return Array(entries.prefix(index + 1)) + members + Array(entries.dropFirst(index + 1))
}

func collapsePhotoPreviewBurst(_ entries: [PhotoPreviewEntry], burstID: String) -> [PhotoPreviewEntry] {
    entries.filter { entry in
        guard case .photo(_, let memberBurstID) = entry else { return true }
        return memberBurstID != burstID
    }
}

func photoPreviewCollectionIndex(_ entries: [PhotoPreviewEntry], memberIndex: Int) -> Int? {
    guard entries.indices.contains(memberIndex), let burstID = entries[memberIndex].burstID else { return nil }
    let collectionIndex = entries.firstIndex { entry in
        if case .burst(let group) = entry { return group.id == burstID }
        return false
    }
    return collectionIndex.flatMap { $0 < memberIndex ? $0 : nil }
}

enum PhotoCatalogGrouping {
    static let unknownDay = "zzz_unknown"

    static func byCaptureDay(_ files: [CameraFile]) -> [PhotoDaySection] {
        var sections: [String: [CameraFile]] = [:]
        for file in files {
            let day = normalizedDay(file.captureDate)
            sections[day, default: []].append(file)
        }
        return sections.keys.sorted { lhs, rhs in
            if lhs == rhs { return false }
            // Android's synthetic `zzz_unknown` key sorts first in descending
            // order, so files without capture time stay at the top.
            return lhs > rhs
        }.map { day in
            // Kotlin's sortedByDescending is stable. Preserve the camera's
            // enumeration order for equal timestamps so JPG/RAW pairs are not
            // reordered by Swift's unspecified equal-element sort behavior.
            let stable = (sections[day] ?? []).enumerated().sorted { lhs, rhs in
                let left = lhs.element.captureDate.orEmpty
                let right = rhs.element.captureDate.orEmpty
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
            return PhotoDaySection(day: day, files: stable)
        }
    }

    /// Same rule as Android: same extension, consecutive filename number and a
    /// 0–1 second capture gap; only runs of at least three are a burst.
    static func bursts(in files: [CameraFile]) -> [BurstPhotoGroup] {
        guard files.count >= 3 else { return [] }
        struct Shot { let file: CameraFile; let number: Int; let daySeconds: Int; let day: String }
        var result: [BurstPhotoGroup] = []
        for (extensionName, values) in Dictionary(grouping: files, by: { $0.fileExtension }) {
            let shots = values.compactMap { file -> Shot? in
                guard let stamp = file.captureDate, stamp.count >= 15 else { return nil }
                let chars = Array(stamp)
                guard let hour = Int(String(chars[9...10])), let minute = Int(String(chars[11...12])), let second = Int(String(chars[13...14])) else { return nil }
                let stem = file.fileName.split(separator: ".", omittingEmptySubsequences: false).dropLast().joined(separator: ".")
                let digits = String(stem.reversed().prefix(while: { $0.isNumber }).reversed())
                guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
                return Shot(file: file, number: number, daySeconds: hour * 3600 + minute * 60 + second, day: String(stamp.prefix(8)))
            }.sorted { $0.day == $1.day ? $0.number < $1.number : $0.day < $1.day }
            guard !shots.isEmpty else { continue }
            var start = 0
            for end in 1...shots.count {
                let broken: Bool
                if end == shots.count { broken = true }
                else {
                    let previous = shots[end - 1], current = shots[end]
                    broken = current.day != previous.day || current.number != previous.number + 1 || current.daySeconds - previous.daySeconds < 0 || current.daySeconds - previous.daySeconds > 1
                }
                if broken {
                    if end - start >= 3 {
                        let first = shots[start]
                        result.append(BurstPhotoGroup(id: "\(extensionName)_\(first.day)_\(first.number)_\(first.file.id)", files: shots[start..<end].map(\.file)))
                    }
                    start = end
                }
            }
        }
        return result
    }

    private static func normalizedDay(_ value: String?) -> String {
        guard let value, value.count >= 8 else { return PhotoCatalogGrouping.unknownDay }
        // Android keeps the raw YYYYMMDD grouping key and formats it only at
        // render time. Keeping that key is required for collapse/filter state
        // and unknown-date ordering to match the source implementation.
        return String(value.prefix(8))
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
