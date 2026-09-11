"""Enumerated page source injection only; old camera/preview/queue implementations remain guarded."""

def once(value, new, old=''):
    assert value.count(new) == 1, new
    return value.replace(new, old, 1)

def without_original_source_page(value):
    value = once(value, '    private let originals: OriginalFilesReading\n')
    value = once(value, '    private(set) var originalIndexTask: Task<Void, Never>?', '    private var originalIndexTask: Task<Void, Never>?')
    value = once(value, '    private(set) var originalRevision: Int64 = -1', '    private var originalRevision: Int64 = -1')
    value = once(value, 'preferences: BrowsePreferencesStore? = nil, originals: OriginalFilesReading? = nil)',
                       'preferences: BrowsePreferencesStore? = nil)')
    value = once(value, '        self.originals = originals ?? queue // One immutable source for the entire page/preview lifetime.\n')
    for method in ('originals', 'originalData', 'originalRawPreviewData', 'originalExif'):
        value = once(value, 'self.originals.' + method + '(', 'self.queue.' + method + '(')
    return value

PROVIDER_ENTRY = '''    func openSharedProviderFiles() {
        guard canOpenSharedWorkspace, !scanningCatalog, !directoryBusy, let connection = apConnection else { return }
        let navigation = workspaceNavigation
        directoryBusy = true
        directoryTask = Task {
            defer { directoryBusy = false; directoryTask = nil }
            do {
                let source = try providerStore()
                try await source.validateSelection() // Freeze the grant before publishing a page, without a double scan.
                try Task.checkCancellation()
                guard canOpenSharedWorkspace, !scanningCatalog, workspaceNavigation == navigation,
                      apConnection?.connectionID == connection.connectionID else { return }
                directoryStatus = "文件页的已保存标记与本地预览使用所选目录；新下载仍写入应用沙盒，自动目录目标尚未接入。"
                openSharedFiles(originals: source)
            } catch {
                if !Task.isCancelled { directoryStatus = "所选目录无法打开：\\(error.localizedDescription)" }
            }
        }
    }
'''

def without_original_source_probe(value):
    value = once(value, '    private var workspaceNavigation: UInt64 = 0\n')
    assert value.count('        workspaceNavigation &+= 1\n') == 2
    value = value.replace('        workspaceNavigation &+= 1\n', '')
    value = once(value, '        filesPage?.close(); filesPage = nil // No frozen preview/index survives a grant change or refresh.\n')
    value = once(value, PROVIDER_ENTRY)
    value = once(value, 'func openSharedFiles(originals: OriginalFilesReading? = nil)', 'func openSharedFiles()')
    value = once(value, 'stationMode: connection.stationMode, originals: originals)', 'stationMode: connection.stationMode)')
    return once(value, '''            Button("打开共享文件浏览（已选原片目录）") { probe.openSharedProviderFiles() }
                .disabled(!probe.canOpenSharedWorkspace || probe.scanningCatalog || probe.directoryBusy)
            Text("已选目录入口只改变已保存识别与本地预览；下载队列当前仍写入应用沙盒。")
                .font(.caption)
''')

SELECTION_VALIDATION = '''    /// Bind before a page or future transfer attempt starts, without scanning or materializing images.
    func validateSelection() async throws {
        let selection = try await boundSelection()
        try await directory.withDirectory(selection: selection) { _ in () }
    }

'''

def without_selection_validation(value): return once(value, SELECTION_VALIDATION)
