"""Exact batch-47 diagnostic additions, not a replacement camera/queue baseline."""
from provider_index_wiring import without_provider_index_probe

PROBE_METHOD = '''    /// Actual provider publication probe; does not yet redirect queue downloads or provider indexes.
    func publishSavedToDirectory(byDate: Bool) {
        guard !directoryBusy, let saved = savedOriginal, saved.url == savedURL else { return }
        let folder = PtpTransferBridge.shared.destinationFolder(captureDate: savedCaptureDate, byDate: byDate,
            dayKey: OriginalFilesPageBridge.localDayKey(at: Date(), timeZone: .current))
        directoryBusy = true
        directoryStatus = "正在向已选目录写入校验副本…"
        directoryTask = Task {
            defer { directoryBusy = false; directoryTask = nil }
            do {
                let directory = try ScopedDirectoryStore.applicationStore()
                let result = try await ProviderOriginalPublisher(directory: directory).publish(saved, folder: folder)
                directoryStatus = "已写入 \\(result.url.lastPathComponent)，\\(result.bytes) 字节，校验一致；应用内原片保留。云端同步由文件服务处理。"
            } catch {
                directoryStatus = Task.isCancelled ? "已取消外部目录写入；应用内原片保留。" : error.localizedDescription
            }
        }
    }

'''

def without_provider_publication_probe(value):
    value = without_provider_index_probe(value)
    for addition in (
        '    private var savedOriginal: SavedCameraFile?\n    private var savedCaptureDate: String?\n',
        PROBE_METHOD,
        '                HStack {\n'
        '                    Button("写入已选目录") { probe.publishSavedToDirectory(byDate: false) }\n'
        '                    Button("按拍摄日期写入已选目录") { probe.publishSavedToDirectory(byDate: true) }\n'
        '                }.font(.caption).disabled(probe.directoryBusy)\n',
    ):
        assert value.count(addition) == 1
        value = value.replace(addition, '', 1)
    new = 'savedURL = nil; savedOriginal = nil; savedCaptureDate = nil'
    assert value.count(new) == 2
    value = value.replace(new, 'savedURL = nil')
    for new, old in (
        ('            Task {\n'
         '                let captureDate = (await queue.snapshot()).rows.first { $0.id == id }?.captureDate\n'
         '                if let saved = await queue.savedFile(id) {\n'
         '                    savedURL = saved.url; savedOriginal = saved; savedCaptureDate = captureDate\n'
         '                }\n'
         '            }',
         '            Task { if let saved = await queue.savedFile(id) { savedURL = saved.url } }'),
        ('                savedURL = saved.url; savedOriginal = saved; savedCaptureDate = info.captureDate',
         '                savedURL = saved.url'),
    ):
        assert value.count(new) == 1
        value = value.replace(new, old, 1)
    return value
