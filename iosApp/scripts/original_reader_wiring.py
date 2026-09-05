"""Reverse only the enumerated Swift reader extraction to retain historical whole-source guards."""
from pathlib import Path
from original_source_wiring import without_original_source_page

ROOT = Path(__file__).resolve().parents[2]
READER = 'iosApp/ZTransfer/Storage/IndexedOriginalReader.swift'
SANDBOX = 'iosApp/ZTransfer/Storage/SandboxTransferFile.swift'

WRAPPERS = '''    /// Capture only a previously indexed entry; the same reader also serves coordinated providers.
    private func reader(locator: String, cancellation: PreviewExifReadCancellation = PreviewExifReadCancellation()) -> IndexedOriginalReader {
        let entry = URL(string: locator).flatMap { originalIndex.entry(at: $0) }
        return IndexedOriginalReader(root: root, entry: entry, cancellation: cancellation)
    }

    func originalData(locator: String) throws -> Data {
        try reader(locator: locator).originalData(locator: locator)
    }

    func originalRawPreviewData(locator: String) throws -> Data? {
        try reader(locator: locator).originalRawPreviewData(locator: locator)
    }

    func originalExif(locator: String) async throws -> PhotoExif? {
        let cancellation = PreviewExifReadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try self.reader(locator: locator, cancellation: cancellation).originalExif(locator: locator)
        }, onCancel: { cancellation.cancel() })
    }

'''

READER_PREFIX = '''import Foundation
import Darwin
import ZTransferShared

/// One implementation for sandbox and scoped provider originals. Immutable index entry only;
/// no index mutation, network, retained open descriptor or escaping provider URL permission.
final class IndexedOriginalReader {
    private let root: URL
    private let entry: OriginalIndexEntry?
    private let cancellation: PreviewExifReadCancellation
    init(root: URL, entry: OriginalIndexEntry?, cancellation: PreviewExifReadCancellation = PreviewExifReadCancellation()) {
        self.root = root; self.entry = entry; self.cancellation = cancellation
    }
    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancellation.isCancelled { throw CancellationError() }
    }

'''

def restore_sandbox_reader(sandbox, reader=None):
    if reader is None:
        reader = (ROOT / READER).read_text(encoding='utf-8')
    if not reader.startswith(READER_PREFIX) or not reader.endswith('\n}\n') or sandbox.count(WRAPPERS) != 1:
        raise ValueError('Reader ownership or delegation changed outside enumerated extraction')
    methods = reader[len(READER_PREFIX):-2]
    methods = methods.replace('Read only the captured index entry. The caller owns the directory grant/coordinated lifetime.',
                              'Read only an indexed app-owned original. Never accepts arbitrary file/provider URLs.')
    methods = methods.replace('try checkCancellation()', 'try Task.checkCancellation()')
    methods = methods.replace('let entry = entry', 'let entry = originalIndex.entry(at: url)')
    start = methods.index('    func originalExif(')
    end = methods.index('    /// Opens once', start)
    exif = methods[start:end]
    body = exif.split(' throws -> PhotoExif? {\n', 1)[1].removesuffix('    }\n\n')
    body = ''.join('    ' + line + '\n' for line in body.splitlines())
    original = '''    func originalExif(locator: String) async throws -> PhotoExif? {
        let cancellation = PreviewExifReadCancellation()
        return try await withTaskCancellationHandler(operation: {
'''+body+'''        }, onCancel: { cancellation.cancel() })
    }

'''
    methods = methods[:start] + original + methods[end:]
    return sandbox.replace(WRAPPERS, methods)

def historical_source(path):
    value = (ROOT / path).read_text(encoding='utf-8')
    if path == 'iosApp/ZTransfer/UI/OriginalFilesPage.swift':
        return without_original_source_page(value)
    return restore_sandbox_reader(value) if path == SANDBOX else value
