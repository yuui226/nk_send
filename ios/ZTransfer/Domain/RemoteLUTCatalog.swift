import Foundation

struct PresetFile: Equatable, Sendable {
    let identifier: String
    let name: String
    let relativePath: String
    let size: Int64?
    var modified: Date? = nil
    var label: String { name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name }
    var category: String? {
        let components = relativePath.split(separator: "/")
        return components.count == 2 ? String(components[0]) : nil
    }
}

typealias RemoteLUTFile = PresetFile

enum RemoteLUTCatalog {
    /// Android lutFileLabels: derive numbering before favorites reorder the list.
    static func labels(_ files: [RemoteLUTFile], uncategorized: String) -> [String: String] {
        struct CategoryKey: Hashable { let group: String; let category: String? }
        var counts: [String: Int] = [:]
        var categoryCounts: [CategoryKey: Int] = [:]
        for file in files {
            let group = file.label.lowercased()
            counts[group, default: 0] += 1
            categoryCounts[CategoryKey(group: group, category: file.category), default: 0] += 1
        }
        var positions: [String: Int] = [:]
        var result: [String: String] = [:]
        for file in files {
            let group = file.label.lowercased()
            positions[group, default: 0] += 1
            let rawName = file.label.isEmpty ? file.name : file.label
            let name = String(decoding: rawName.utf16.prefix(256), as: UTF16.self)
            if counts[group, default: 0] > 1 {
                let duplicate = categoryCounts[CategoryKey(group: group, category: file.category), default: 0] > 1
                result[file.identifier] = [name, file.category ?? uncategorized,
                    duplicate ? String(positions[group, default: 0]) : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            } else {
                result[file.identifier] = name
            }
        }
        return result
    }

    static func photoFolderStatus(hasFolder: Bool, loading: Bool, failure: String?) -> String {
        if !hasFolder { return "photo_lut_set_folder" }
        if let failure { return failure }
        return loading ? "lut_reading_folder" : "lut_folder_empty"
    }

    /// Android scans LUT files in the selected root and one category level.
    /// Deeper descendants and non-cube files are intentionally excluded.
    static func visibleFiles(_ files: [RemoteLUTFile], fileExtension: String = "cube") -> [RemoteLUTFile] {
        files.filter {
            $0.name.lowercased().hasSuffix("." + fileExtension.lowercased()) &&
            $0.relativePath.split(separator: "/").count <= 2
        }.sorted {
            let first = $0.name.lowercased()
            let second = $1.name.lowercased()
            if first != second { return first.utf16.lexicographicallyPrecedes(second.utf16) }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.identifier < $1.identifier
        }
    }
}

/// Mirrors LutCategoryList: locate a changed selection, but preserve a category
/// the user opened when a background refresh leaves it available.
struct PhotoLUTCategorySelection {
    var category: String?
    private var positionedSelection: String?

    static func categories(in files: [RemoteLUTFile]) -> [String?] {
        var seen = Set<String?>()
        return files.map(\.category).filter { seen.insert($0).inserted }.sorted {
            guard let first = $0 else { return $1 != nil }
            guard let second = $1 else { return false }
            if first.lowercased() != second.lowercased() {
                return first.lowercased().utf16.lexicographicallyPrecedes(second.lowercased().utf16)
            }
            return first.utf16.lexicographicallyPrecedes(second.utf16)
        }
    }

    mutating func reconcile(files: [RemoteLUTFile], selected: String?) {
        if selected != positionedSelection, let file = files.first(where: { $0.identifier == selected }) {
            category = file.category
            positionedSelection = selected
        }
        if selected == nil { positionedSelection = nil }
        let available = Self.categories(in: files)
        if !available.contains(category) { category = available.first ?? nil }
    }
}
