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
        struct CategoryKey: Hashable { let group: Data; let category: Data? }
        var counts: [Data: Int] = [:]
        var categoryCounts: [CategoryKey: Int] = [:]
        for file in files {
            let group = Data(file.label.lowercased().utf8)
            counts[group, default: 0] += 1
            categoryCounts[CategoryKey(group: group, category: file.category.presetCategoryBytes), default: 0] += 1
        }
        var positions: [Data: Int] = [:]
        var result: [String: String] = [:]
        for file in files {
            let group = Data(file.label.lowercased().utf8)
            positions[group, default: 0] += 1
            let rawName = file.label.isEmpty ? file.name : file.label
            let name = String(decoding: rawName.utf16.prefix(256), as: UTF16.self)
            if counts[group, default: 0] > 1 {
                let duplicate = categoryCounts[CategoryKey(group: group, category: file.category.presetCategoryBytes), default: 0] > 1
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
        sortedFiles(files.filter {
            $0.name.lowercased().hasSuffix("." + fileExtension.lowercased()) &&
            $0.relativePath.split(separator: "/").count <= 2
        })
    }

    static func sortedFiles(_ files: [PresetFile]) -> [PresetFile] {
        // Cache the simple case mapping once per name, outside O(N log N)
        // comparisons. Java's final name/URI ties compare raw UTF-16 units.
        var caseCache: [UInt16: UInt16] = [:]
        return files.map { (file: $0, folded: PresetTextOrder.folded($0.name, cache: &caseCache)) }.sorted {
            if $0.folded != $1.folded { return $0.folded.lexicographicallyPrecedes($1.folded) }
            if !$0.file.name.utf16.elementsEqual($1.file.name.utf16) {
                return $0.file.name.utf16.lexicographicallyPrecedes($1.file.name.utf16)
            }
            return $0.file.identifier.utf16.lexicographicallyPrecedes($1.file.identifier.utf16)
        }.map(\.file)
    }
}

/// Android libcore String.CaseInsensitiveComparator compares charAt(), not
/// whole-string lowercase/case folding or Unicode scalar collation. Surrogates
/// remain separate. UnicodeData simple mappings also differ from full mappings
/// for Greek iota-subscript capitals and dotted I; never expand one char to two.
enum PresetTextOrder {
    static func folded(_ value: String) -> [UInt16] {
        var cache: [UInt16: UInt16] = [:]
        return folded(value, cache: &cache)
    }
    static func folded(_ value: String, cache: inout [UInt16: UInt16]) -> [UInt16] {
        value.utf16.map { unit in
            if unit < 128 { return (65...90).contains(unit) ? unit + 32 : unit }
            if let mapped = cache[unit] { return mapped }
            guard let scalar = UnicodeScalar(unit), scalar.properties.isCased else { return unit }
            let fullUpper = String(scalar).uppercased().utf16
            let upper: UInt16
            if fullUpper.count == 1 { upper = fullUpper.first! }
            else {
                switch unit {
                case 0x1F80...0x1F87, 0x1F90...0x1F97, 0x1FA0...0x1FA7: upper = unit + 8
                case 0x1FB3: upper = 0x1FBC
                case 0x1FC3: upper = 0x1FCC
                case 0x1FF3: upper = 0x1FFC
                default: upper = unit
                }
            }
            if upper == 0x0130 { cache[unit] = 0x0069; return 0x0069 }
            let lower = String(UnicodeScalar(upper)!).lowercased().utf16
            let result = lower.count == 1 ? lower.first! : upper
            cache[unit] = result
            return result
        }
    }
}

extension Optional where Wrapped == String {
    // Swift String equality normalizes composed/decomposed spelling; Java
    // category identity does not. Keep exact provider names in maps and UI IDs.
    var presetCategoryBytes: Data? { map { Data($0.utf8) } }
    var presetCategoryIdentifier: String {
        map { "folder:" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0) } ?? "root"
    }
}

/// Mirrors LutCategoryList: locate a changed selection, but preserve a category
/// the user opened when a background refresh leaves it available.
struct PhotoLUTCategorySelection {
    var category: String?
    private var positionedSelection: String?

    static func categories(in files: [RemoteLUTFile]) -> [String?] {
        var seen = Set<Data?>()
        var caseCache: [UInt16: UInt16] = [:]
        return files.map(\.category).filter { seen.insert($0.presetCategoryBytes).inserted }
            .map { (name: $0, folded: PresetTextOrder.folded($0 ?? "", cache: &caseCache)) }.sorted {
            guard let first = $0.name else { return $1.name != nil }
            guard let second = $1.name else { return false }
            if $0.folded != $1.folded {
                return $0.folded.lexicographicallyPrecedes($1.folded)
            }
            return first.utf16.lexicographicallyPrecedes(second.utf16)
        }.map(\.name)
    }

    @MainActor
    mutating func reconcile(catalog: PresetCatalogIndex, selected: String?) {
        if selected != positionedSelection, let selected, let file = catalog.filesByIdentifier[selected] {
            category = file.category
            positionedSelection = selected
        }
        if selected == nil { positionedSelection = nil }
        if !catalog.categories.contains(where: { $0.presetCategoryBytes == category.presetCategoryBytes }) { category = catalog.categories.first ?? nil }
    }

    mutating func reconcile(files: [RemoteLUTFile], selected: String?) {
        if selected != positionedSelection, let file = files.first(where: { $0.identifier == selected }) {
            category = file.category
            positionedSelection = selected
        }
        if selected == nil { positionedSelection = nil }
        let available = Self.categories(in: files)
        if !available.contains(where: { $0.presetCategoryBytes == category.presetCategoryBytes }) { category = available.first ?? nil }
    }
}

/// Bounded to the current scan, with one localized label map and one current
/// option list. Source order supplies duplicate-name numbering; favorite order
/// affects the wheel and each category without renumbering those labels.
/// Shared metadata indexing for photo LUT, monitor LUT and NP3; each owner
/// retains its own snapshot, requests, preferences and selected category.
@MainActor
final class PresetCatalogIndex {
    let orderedFiles: [RemoteLUTFile]
    let categories: [String?]
    let filesByIdentifier: [String: RemoteLUTFile]
    private let filesByCategory: [Data?: [RemoteLUTFile]]
    private lazy var labelsByCategory = filesByCategory.mapValues { $0.map(\.label) }
    func files(in category: String?) -> [RemoteLUTFile]? { filesByCategory[category.presetCategoryBytes] }
    func labels(in category: String?) -> [String]? { labelsByCategory[category.presetCategoryBytes] }
    private let files: [RemoteLUTFile]
    private lazy var baseOptions: [String?] = [nil] + orderedFiles.map { Optional($0.identifier) }
    private var localizedLabels: (uncategorized: String, values: [String: String])?
    private var currentOptions: (current: String?, values: [String?])?

    init(files: [RemoteLUTFile], orderedFiles: [RemoteLUTFile]? = nil) {
        self.files = files
        self.orderedFiles = orderedFiles ?? files
        categories = PhotoLUTCategorySelection.categories(in: files)
        filesByIdentifier = Dictionary(uniqueKeysWithValues: files.map { ($0.identifier, $0) })
        filesByCategory = Dictionary(grouping: orderedFiles ?? files) { $0.category.presetCategoryBytes }
    }

    func labels(uncategorized: String) -> [String: String] {
        if let localizedLabels, localizedLabels.uncategorized == uncategorized { return localizedLabels.values }
        let result = RemoteLUTCatalog.labels(files, uncategorized: uncategorized)
        localizedLabels = (uncategorized, result)
        return result
    }

    func selectionOptions(current: String?) -> [String?] {
        if let currentOptions, currentOptions.current == current { return currentOptions.values }
        var result = baseOptions
        // A restored private snapshot remains selectable during a failed scan.
        if let current, filesByIdentifier[current] == nil { result.append(current) }
        currentOptions = (current, result)
        return result
    }
}
