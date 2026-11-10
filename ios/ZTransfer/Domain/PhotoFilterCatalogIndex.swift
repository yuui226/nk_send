import Foundation

/// PhotoFilterEditor.kt: the selectable identity is a source URI, while
/// favorites and parameter memories use content identity. Never coalesce two
/// documents merely because they contain the same built-in/custom recipe.
enum PhotoFilterChoice: Equatable {
    case preset(PhotoFilterPreset, source: String? = nil)
    case document(PresetFile, presetID: String?)

    var key: String {
        switch self {
        case .preset(let preset, let source): source.map { "document:" + $0 } ?? "preset:\(preset.id)"
        case .document(let file, _): "document:" + file.identifier
        }
    }
    var presetID: String? {
        switch self {
        case .preset(let preset, _): preset.id
        case .document(_, let id): id
        }
    }
    var catalogKey: String? { presetID.flatMap(PhotoFilterPreferences.catalogKey) }
}

/// A single immutable directory/selection index. Loading progress and control
/// detents do not rebuild these arrays/maps. Labels are localized independently
/// and duplicate ordinals are assigned before favorite ordering.
@MainActor
final class PhotoFilterCatalogIndex {
    struct Category {
        let key: String
        let builtIn: PhotoEffectFilterCategory?
        let directory: String?
        let choices: [PhotoFilterChoice]
    }
    let choices: [PhotoFilterChoice]
    let byKey: [String: PhotoFilterChoice]
    let categories: [Category]
    let selectionOptions: [String?]
    let currentKey: String?
    let favoriteKeys: Set<String>
    private let fileIndex: PresetCatalogIndex
    private let offline: PhotoFilterChoice?
    private let sourceLabel: PhotoNp3SourceLabel?
    private var cachedLabels: (locale: String, uncategorized: String, fallback: String, values: [String: String])?

    init(files: [PresetFile], failure: RemoteLUTFolderAccessError?, hints: [String: String],
         sourceRecipe: PhotoNp3Recipe?, source: String?, sourceLabel: PhotoNp3SourceLabel?,
         selected: PhotoFilterPreset?, favorites: [String]) {
        let accessible = failure != .missing && failure != .denied
        let files = accessible ? files : []
        fileIndex = PresetCatalogIndex(files: files)
        self.sourceLabel = sourceLabel
        let favoriteSet = Set(favorites)
        favoriteKeys = favoriteSet
        var ranks: [String: Int] = [:]
        for (index, key) in favorites.enumerated() where ranks[key] == nil { ranks[key] = index }
        func ordered(_ values: [PhotoFilterChoice]) -> [PhotoFilterChoice] {
            guard !ranks.isEmpty else { return values }
            return values.enumerated().sorted {
                let first = $0.element.catalogKey.flatMap { ranks[$0] } ?? Int.max
                let second = $1.element.catalogKey.flatMap { ranks[$0] } ?? Int.max
                return first == second ? $0.offset < $1.offset : first < second
            }.map(\.element)
        }
        let builtIns = PhotoFilterCatalog.presets.map { PhotoFilterChoice.preset($0) }
        let documents = files.map { file in
            PhotoFilterChoice.document(file, presetID: hints[file.identifier] ??
                (source == file.identifier ? sourceRecipe?.preset.id : nil))
        }
        let bySource = Dictionary(uniqueKeysWithValues: zip(files.map(\.identifier), documents))
        let matchesDraft = selected != nil && selected?.id == sourceRecipe?.preset.id
        let selectedSource = matchesDraft ? source : nil
        let document = selectedSource.flatMap { bySource[$0] }
        let offline: PhotoFilterChoice?
        if let selected, document == nil, PhotoNp3RecipeKind.from(id: selected.id) != nil {
            offline = .preset(selected, source: selectedSource)
        } else { offline = nil }
        self.offline = offline
        let orderedChoices = ordered(builtIns + documents + (offline.map { [$0] } ?? []))
        choices = orderedChoices
        let keyedChoices = Dictionary(uniqueKeysWithValues: orderedChoices.map { ($0.key, $0) })
        byKey = keyedChoices
        let builtInKey = selected.map { "preset:" + $0.id }
        currentKey = document?.key ?? offline?.key ?? builtInKey.flatMap { keyedChoices[$0] != nil ? $0 : nil }
        selectionOptions = [nil] + orderedChoices.map { Optional($0.key) }
        let sourceIndex = fileIndex
        categories = [PhotoEffectFilterCategory.all, .favorites].map { category in
            let members: [PhotoFilterChoice]
            switch category {
            case .all: members = orderedChoices
            case .favorites: members = orderedChoices.filter { $0.catalogKey.map(favoriteSet.contains) == true }
            default:
                members = ordered(builtIns.filter {
                    if case .preset(let preset, _) = $0 { return preset.category == category }
                    return false
                })
            }
            return Category(key: "builtin:" + category.rawValue, builtIn: category, directory: nil, choices: members)
        } + sourceIndex.categories.map { category in
            Category(key: "directory:" + category.presetCategoryIdentifier,
                builtIn: nil, directory: category,
                choices: ordered((sourceIndex.files(in: category) ?? []).compactMap { bySource[$0.identifier] }))
        }
    }

    func currentKey(enabled: Bool) -> String? { enabled ? currentKey : nil }
    func pendingKey(source: String?) -> String? {
        guard let source else { return nil }
        let key = "document:" + source
        guard case .document = byKey[key] else { return nil }
        return key
    }

    func labels(locale: String, uncategorized: String, restoredSourceFallback: String,
                builtInLabel: (PhotoFilterPreset) -> String) -> [String: String] {
        if let cachedLabels, cachedLabels.locale == locale,
           cachedLabels.uncategorized == uncategorized, cachedLabels.fallback == restoredSourceFallback {
            return cachedLabels.values
        }
        var result = Dictionary(uniqueKeysWithValues: PhotoFilterCatalog.presets.map {
            ("preset:" + $0.id, builtInLabel($0))
        })
        for (source, label) in fileIndex.labels(uncategorized: uncategorized) { result["document:" + source] = label }
        if let offline, case .preset(let preset, let source) = offline {
            result[offline.key] = source == nil ? preset.name
                : sourceLabel?.displayName(uncategorized: uncategorized) ?? restoredSourceFallback
        }
        cachedLabels = (locale, uncategorized, restoredSourceFallback, result)
        return result
    }
}

/// PresetCategoryBrowser follows a genuinely changed selection. A directory
/// refresh must preserve the category the user opened if it still exists.
struct PhotoFilterCategorySelection {
    private(set) var key: String?
    private var positionedSelection: String?

    mutating func select(_ key: String) { self.key = key }
    @MainActor mutating func reconcile(catalog: PhotoFilterCatalogIndex, selected: String?) {
        if selected != positionedSelection,
           let group = catalog.categories.first(where: { $0.choices.contains { $0.key == selected } }) {
            key = group.key
        }
        positionedSelection = selected
        if !catalog.categories.contains(where: { $0.key == key }) { key = catalog.categories.first?.key }
    }
}
