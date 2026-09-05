"""Only batch-48 index/selection additions, removed before older entire-file comparisons."""
from original_source_wiring import without_original_source_probe
from queue_destination_wiring import without_destination_probe

def remove_once(value, text):
    assert value.count(text) == 1, text
    return value.replace(text, '', 1)

def without_provider_index_cache(value):
    value = value.replace('/// Each instance belongs to one store/operation. No second observer, worker or persistent database.',
                          "/// Accessed only by CameraOriginalStore's actor. No second observer, worker or persistent database.")
    value = value.replace('    func scan(root: URL, missingRootIsEmpty: Bool = true,\n'
                          '              checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {',
                          '    func scan(root: URL) throws {')
    assert value.count('try checkCancellation()') == 3
    value = value.replace('try checkCancellation()', 'try Task.checkCancellation()')
    value = value.replace('if missingRootIsEmpty && failure.domain == NSCocoaErrorDomain &&', 'if failure.domain == NSCocoaErrorDomain &&')
    value = remove_once(value, '''    /// Accept a completed scan produced by an operation-local cache, on this instance's owning actor.
    func replaceEntries(_ values: [OriginalIndexEntry]) {
        var candidate: [URL: OriginalIndexEntry] = [:]
        for entry in values { candidate[entry.url] = entry }
        publishFull(candidate)
    }

''')
    value = value.replace('func record(_ saved: SavedCameraFile, folder: String?, canonicalURL: URL? = nil)',
                          'func record(_ saved: SavedCameraFile, folder: String?)')
    return value.replace('url: canonicalURL ?? saved.url.standardizedFileURL.resolvingSymlinksInPath()',
                          'url: saved.url.standardizedFileURL.resolvingSymlinksInPath()')

def without_directory_selection(value):
    value = remove_once(value, '''
/// Opaque bytes, not a path or an active security scope. Never log or export the bookmark.
struct ExportDirectorySelection: Sendable, Equatable {
    fileprivate let bookmark: Data
}
''')
    value = value.replace('case missing, invalidBookmark, permissionLost, notDirectory, selectionChanged',
                          'case missing, invalidBookmark, permissionLost, notDirectory')
    value = remove_once(value, '        case .selectionChanged: return "保存目录授权已变化，请重新打开当前目录；不会改写到另一个位置。"\n')
    start = value.index('    /// Freeze the selected grant.')
    end = value.index('    func displayName()', start)
    return value[:start] + value[end:]

def without_provider_index_probe(value):
    value = without_destination_probe(value)
    value = without_original_source_probe(value)
    for addition in (
        '    private var providerOriginals: ProviderOriginalStore?\n',
        '                    providerOriginals = nil\n',
        '                    providerOriginals = nil // A select/stale-bookmark refresh establishes a new binding.\n',
        '                Button("检查目标原片索引") { probe.inspectProviderOriginals() }\n',
    ):
        value = remove_once(value, addition)
    start = value.index('    private func providerStore()')
    end = value.index('    /// Actual provider publication probe;', start)
    value = value[:start] + value[end:]
    value = value.replace('    /// Actual provider publication probe; queue targets and shared-page indexes are still separate work.',
                          '    /// Actual provider publication probe; does not yet redirect queue downloads or provider indexes.')
    new = '                let result = try await providerStore().publish(saved, folder: folder)'
    assert value.count(new) == 1
    return value.replace(new, '                let directory = try ScopedDirectoryStore.applicationStore()\n'
                        '                let result = try await ProviderOriginalPublisher(directory: directory).publish(saved, folder: folder)', 1)
