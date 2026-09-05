"""Remove only the batch-41 priority additions before older whole-file baseline comparisons."""


def without_priority_connection(value):
    for public, private, arguments, call in (
        ('fhdPicture', 'readFhdPicture', 'handle: Int32, retryDeviceBusy: Bool = true', 'handle: handle, retryDeviceBusy: retryDeviceBusy'),
        ('exifHeader', 'readExifHeader', 'handle: Int32, maximumBytes: Int32', 'handle: handle, maximumBytes: maximumBytes'),
    ):
        private_arguments = arguments.replace(' = true', '')
        wrapper = (f'    func {public}({arguments}) async throws -> Data? {{\n'
                   '        try await withInteractivePreviewPriority {\n'
                   f'            try await self.{private}({call})\n'
                   '        }\n    }\n\n'
                   f'    private func {private}({private_arguments}) async throws -> Data? {{')
        assert value.count(wrapper) == 1
        value = value.replace(wrapper, f'    func {public}({arguments}) async throws -> Data? {{', 1)
    start = value.index('    /// Borrow the same command owner')
    end = value.index('    private func previewCommand(operation: Int32, handle:', start)
    return value[:start] + value[end:]


def without_priority_page(value):
    additions = (
        '    private var previewPriorities: [String: Task<UUID?, Never>] = [:]\n',
        '        endPreviewPriority(sessionId: sessionId, requestId: requestId)\n',
        '        for key in Array(previewPriorities.keys) where key.hasPrefix("\\(sessionId):") { endPreviewPriority(key: key) }\n',
    )
    for addition in additions:
        assert value.count(addition) == 1
        value = value.replace(addition, '', 1)
    start = value.index('    func beginPreviewPriority(')
    end = value.index('    func readFhdPreview(', start)
    return value[:start] + value[end:]
