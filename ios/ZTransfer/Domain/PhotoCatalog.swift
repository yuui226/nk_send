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

enum PhotoCatalogGrouping {
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
            if lhs == "__unknown__" { return true }
            if rhs == "__unknown__" { return false }
            return lhs > rhs
        }.map { day in
            PhotoDaySection(day: day, files: (sections[day] ?? []).sorted { $0.captureDate.orEmpty > $1.captureDate.orEmpty })
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
        guard let value, value.count >= 8 else { return "__unknown__" }
        let chars = Array(value.prefix(8))
        return "\(chars[0])\(chars[1])\(chars[2])\(chars[3])-\(chars[4])\(chars[5])-\(chars[6])\(chars[7])"
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
