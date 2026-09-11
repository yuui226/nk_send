import Foundation
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

    /// Read only the captured index entry. The caller owns the directory grant/coordinated lifetime.
    /// No network access or index rescan on a preview request; deletion/size change fails locally.
    func originalData(locator: String) throws -> Data {
        try withOriginalInput(locator: locator, maximumFileBytes: 256 * 1024 * 1024) { input, size in
            var data = Data()
            var remaining = size
            while remaining > 0 {
                try checkCancellation()
                let chunk = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
                guard !chunk.isEmpty else { throw OriginalIndexError.incompleteMetadata }
                data.append(chunk); remaining -= Int64(chunk.count)
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw OriginalIndexError.incompleteMetadata }
            var finalState = stat()
            guard fstat(input.fileDescriptor, &finalState) == 0, finalState.st_size == size else {
                throw OriginalIndexError.incompleteMetadata
            }
            try checkCancellation()
            return data
        }
    }

    /// Same indexed owner/descriptor checks, but only bounded slices of a potentially large RAW.
    func originalRawPreviewData(locator: String) throws -> Data? {
        try withOriginalInput(locator: locator, maximumFileBytes: Int64.max) { input, size in
            let prefixCount = Int(min(size, Int64(LocalRawPreviewPolicy.shared.indexPrefixBytes)))
            let prefix = try readOriginalRange(input, offset: 0, count: prefixCount, size: size)
            let references = NativeRawPreviewBridge.shared.candidates(data: prefix as NSData)
            var bestBytes: Data?
            var bestPixels: Int64 = -1
            for reference in references {
                try checkCancellation()
                let offset = reference.offset, length = Int64(reference.length)
                // Invalid/out-of-file candidates are misses, not permission to read another file.
                guard offset >= 0, length > 0, offset <= size, length <= size - offset else { continue }
                let bytes: Data
                if offset + length <= Int64(prefix.count) {
                    bytes = prefix.subdata(in: Int(offset)..<Int(offset + length))
                } else {
                    bytes = try readOriginalRange(input, offset: offset, count: Int(length), size: size)
                }
                let pixels = try PreviewImageDecoder.rawPreviewPixels(bytes)
                if LocalRawPreviewPolicy.shared.isBetter(pixelCount: pixels, previous: bestPixels) {
                    bestPixels = pixels; bestBytes = bytes
                }
            }
            var finalState = stat()
            guard fstat(input.fileDescriptor, &finalState) == 0, finalState.st_size == size else {
                throw OriginalIndexError.incompleteMetadata
            }
            try checkCancellation()
            return bestBytes
        }
    }

    private func readOriginalRange(_ input: FileHandle, offset: Int64, count: Int, size: Int64) throws -> Data {
        try checkCancellation()
        guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
            throw OriginalIndexError.incompleteMetadata
        }
        try input.seek(toOffset: UInt64(offset))
        var data = Data(), remaining = count
        while remaining > 0 {
            try checkCancellation()
            let chunk = try input.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
            guard !chunk.isEmpty else { throw OriginalIndexError.incompleteMetadata }
            data.append(chunk); remaining -= chunk.count
        }
        try checkCancellation()
        return data
    }

    func originalExif(locator: String) throws -> PhotoExif? {
        try self.withOriginalInput(locator: locator, maximumFileBytes: Int64.max) { input, size in
            let exif = try PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: size, cancellation: cancellation)
            var finalState = stat()
            guard fstat(input.fileDescriptor, &finalState) == 0, finalState.st_size == size else {
                throw OriginalIndexError.incompleteMetadata
            }
            try checkCancellation()
            return exif
        }
    }

    /// Stream to an app-owned private part while the caller still owns the provider scope/accessor.
    /// The caller commits only AFTER this method and coordination return successfully.
    func copyOriginal(_ reference: ExistingOriginalReference, to output: SandboxTransferFile) throws -> Int64 {
        guard entry?.name == reference.name, entry?.size == reference.size else {
            throw OriginalIndexError.incompleteMetadata
        }
        return try withOriginalInput(locator: reference.locator, maximumFileBytes: Int64.max, allowEmpty: true) { input, size in
            var remaining = size
            while remaining > 0 {
                try checkCancellation()
                let chunk = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
                guard !chunk.isEmpty else { throw OriginalIndexError.incompleteMetadata }
                try output.write(chunk)
                remaining -= Int64(chunk.count)
            }
            var finalState = stat()
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty,
                  fstat(input.fileDescriptor, &finalState) == 0, finalState.st_size == size else {
                throw OriginalIndexError.incompleteMetadata
            }
            try checkCancellation()
            return size
        }
    }

    /// Opens once without following directory/leaf links, and closes on every return/throw.
    private func withOriginalInput<T>(locator: String, maximumFileBytes: Int64,
                                      allowEmpty: Bool = false,
                                      body: (FileHandle, Int64) throws -> T) throws -> T {
        try checkCancellation()
        guard let url = URL(string: locator), url.isFileURL,
              url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
              let entry = entry, entry.url.absoluteString == locator,
              (entry.size > 0 || (allowEmpty && entry.size == 0)), entry.size <= maximumFileBytes,
              SandboxTransferFile.safeComponent(entry.name),
              !SandboxTransferFile.isPrivatePartName(entry.name) else { throw OriginalIndexError.unsafeRoot }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
            throw OriginalIndexError.unsafeRoot
        }
        let parent = entry.folder.map { canonicalRoot.appendingPathComponent($0, isDirectory: true) } ?? canonicalRoot
        guard (entry.folder == nil || NativeOriginalIndexPolicy.shared.isDateFolder(name: entry.folder!)),
              try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
              parent.standardizedFileURL.resolvingSymlinksInPath() == parent,
              url.deletingLastPathComponent() == parent,
              url.standardizedFileURL.resolvingSymlinksInPath() == url else { throw OriginalIndexError.unsafeRoot }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink == false, values.isRegularFile == true,
              values.fileSize.map(Int64.init) == entry.size else { throw OriginalIndexError.incompleteMetadata }
        // Hold each directory descriptor and open the next component without following symlinks.
        // Replacing a date folder or leaf between the URL checks and open cannot redirect this read.
        let rootFD = canonicalRoot.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw OriginalIndexError.unsafeRoot }
        defer { _ = Darwin.close(rootFD) }
        let folderFD: Int32
        if let folder = entry.folder {
            folderFD = folder.withCString { Darwin.openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0) }
            guard folderFD >= 0 else { throw OriginalIndexError.unsafeRoot }
        } else { folderFD = rootFD }
        defer { if folderFD != rootFD { _ = Darwin.close(folderFD) } }
        let fileFD = entry.name.withCString { Darwin.openat(folderFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0) }
        guard fileFD >= 0 else { throw OriginalIndexError.unsafeRoot }
        let input = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        defer { try? input.close() }
        var opened = stat()
        guard fstat(fileFD, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_size == entry.size else { throw OriginalIndexError.incompleteMetadata }
        return try body(input, entry.size)
    }

}
