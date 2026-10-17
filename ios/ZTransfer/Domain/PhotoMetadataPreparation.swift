import Foundation
import Darwin

/// Structural completeness follows Android JpegMetadataHeader. Missing camera
/// fields alone never imply truncation (a complete EXIF may legitimately be sparse).
enum JpegMetadataHeader: Equatable, Sendable {
    case exifComplete, noExif, incomplete, invalid

    static func inspect(_ data: Data) -> Self {
        // Data slices may have a nonzero startIndex.
        let bytes = data[data.startIndex...]
        func byte(_ index: Int) -> UInt8 { bytes[bytes.startIndex + index] }
        guard bytes.count >= 2 else { return .incomplete }
        guard byte(0) == 255, byte(1) == 0xd8 else { return .invalid }
        var offset = 2
        while offset < bytes.count {
            guard byte(offset) == 255 else { return .invalid }
            offset += 1
            while offset < bytes.count, byte(offset) == 255 { offset += 1 }
            guard offset < bytes.count else { return .incomplete }
            let marker = byte(offset); offset += 1
            if marker == 0xda || marker == 0xd9 { return .noExif }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            if marker == 0 || marker == 0xd8 { return .invalid }
            guard bytes.count - offset >= 2 else { return .incomplete }
            let length = Int(byte(offset)) * 256 + Int(byte(offset + 1))
            guard length >= 2 else { return .invalid }
            guard length <= bytes.count - offset else { return .incomplete }
            if marker == 0xe1, length >= 8,
               (0..<6).allSatisfy({ byte(offset + 2 + $0) == [69, 120, 105, 102, 0, 0][$0] }) {
                return .exifComplete
            }
            offset += length
        }
        return .incomplete
    }
}

struct PreparedPhotoMetadata: Equatable, Sendable {
    enum State: Sendable { case complete, noExif, partial, failed }
    let value: PhotoFrameMetadata?
    let state: State

    static func parse(_ header: Data) -> Self {
        let structure = JpegMetadataHeader.inspect(header)
        switch structure {
        case .noExif: return Self(value: nil, state: .noExif)
        case .invalid: return Self(value: nil, state: .failed)
        case .incomplete, .exifComplete:
            let exif = PhotoExifParser.parse(header)
            return Self(value: exif.map { PhotoFrameMetadata($0).boundedForQueue() },
                        state: structure == .incomplete ? .partial : (exif == nil ? .failed : .complete))
        }
    }

    func merging(previous: PhotoFrameMetadata?) -> Self {
        guard let previous else { return self }
        guard let value else { return Self(value: previous, state: state) }
        func label(_ next: String?, _ old: String?) -> String? {
            guard let next, !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return old }
            return next
        }
        let merged = PhotoFrameMetadata(make: label(value.make, previous.make), model: label(value.model, previous.model),
            lensModel: label(value.lensModel, previous.lensModel), focalLength: label(value.focalLength, previous.focalLength),
            aperture: label(value.aperture, previous.aperture), shutter: label(value.shutter, previous.shutter),
            iso: label(value.iso, previous.iso), exposureCompensation: value.exposureCompensation,
            dateTime: label(value.dateTime, previous.dateTime), latitude: value.latitude ?? previous.latitude,
            longitude: value.longitude ?? previous.longitude, altitude: value.altitude ?? previous.altitude,
            city: label(value.city, previous.city), region: label(value.region, previous.region))
        return Self(value: merged.boundedForQueue(), state: state)
    }
}

/// Actor-owned, bounded access-order cache. NO_EXIF and final PARTIAL results
/// are useful hits too; FAILED results must remain retryable.
struct PhotoMetadataResultCache<Key: Hashable & Sendable>: Sendable {
    private var values: [Key: PreparedPhotoMetadata] = [:]
    private var order: [Key] = []
    let capacity: Int
    init(capacity: Int = 256) { precondition(capacity > 0); self.capacity = capacity }
    var count: Int { values.count }
    mutating func value(for key: Key) -> PreparedPhotoMetadata? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return value
    }
    mutating func insert(_ value: PreparedPhotoMetadata, for key: Key) {
        guard value.state != .failed else { return }
        values[key] = value
        order.removeAll { $0 == key }; order.append(key)
        if order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    mutating func removeAll() { values.removeAll(); order.removeAll() }
}

/// Both captured and supplemental headers use the same low-priority actor.
/// Synchronous parse methods cannot interleave, matching Android's single
/// metadata executor while camera I/O remains independently suspendable.
actor PhotoMetadataParser {
    func parse(_ header: PhotoMetadataHeaderStore.Header) throws -> PreparedPhotoMetadata {
        PreparedPhotoMetadata.parse(try header.read())
    }
    func parse(_ data: Data) -> PreparedPhotoMetadata { PreparedPhotoMetadata.parse(data) }
}

/// Captured headers have a separate budget from small generation recipes.
/// A ticket owns its bytes/file until the parser (or a cancelled pending job)
/// releases it; closing the store never removes an active reader's file.
final class PhotoMetadataHeaderStore: @unchecked Sendable {
    private static let processID = UUID().uuidString
    private let lock = NSLock()
    private let memoryLimit: Int
    private let diskLimit: Int
    private var memoryBytes = 0
    private var diskBytes = 0
    private var closed = false
    private let sessionDirectory: URL
    private let cleanup: Task<Void, Never>

    struct Usage: Equatable, Sendable {
        let memoryBytes: Int
        let diskBytes: Int
    }

    final class Header: Sendable {
        fileprivate enum Payload: Sendable { case memory(Data), disk(URL) }
        fileprivate let payload: Payload
        fileprivate let size: Int
        private let owner: PhotoMetadataHeaderStore
        fileprivate init(payload: Payload, size: Int, owner: PhotoMetadataHeaderStore) {
            self.payload = payload; self.size = size; self.owner = owner
        }
        func read() throws -> Data {
            switch payload {
            case .memory(let data): return data
            case .disk(let url): return try Data(contentsOf: url)
            }
        }
        deinit { owner.release(payload, size: size) }
    }

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photo-metadata-headers", isDirectory: true),
         memoryLimit: Int = 2 * 1024 * 1024, diskLimit: Int = 16 * 1024 * 1024) {
        precondition(memoryLimit >= 0 && diskLimit >= 0)
        self.memoryLimit = memoryLimit; self.diskLimit = diskLimit
        let processDirectory = directory.appendingPathComponent(Self.processID, isDirectory: true)
        sessionDirectory = processDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Multiple queues in this process may still own their own session files.
        // Only previous-process directories are eligible for startup cleanup.
        cleanup = Task.detached(priority: .utility) {
            let old = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)) ?? []
            for url in old where url != processDirectory { try? FileManager.default.removeItem(at: url) }
        }
    }

    var usage: Usage {
        lock.lock(); defer { lock.unlock() }
        return Usage(memoryBytes: memoryBytes, diskBytes: diskBytes)
    }

    private enum Reservation { case memory, disk }
    private func reserve(_ size: Int) -> Reservation? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        if size <= memoryLimit - memoryBytes { memoryBytes += size; return .memory }
        if size <= diskLimit - diskBytes { diskBytes += size; return .disk }
        return nil
    }
    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }; return closed
    }

    /// Admission only waits for an overflow spool write, never for parsing.
    func retain(_ data: Data) async throws -> Header? {
        try Task.checkCancellation()
        guard let reservation = reserve(data.count) else { return nil }
        switch reservation {
        case .memory:
            return Header(payload: .memory(data), size: data.count, owner: self)
        case .disk:
            let url = sessionDirectory.appendingPathComponent(UUID().uuidString + ".header")
            var transferred = false
            defer { if !transferred { release(.disk(url), size: data.count) } }
            await cleanup.value
            let directory = sessionDirectory
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
            }.value
            try Task.checkCancellation()
            guard !isClosed else { return nil }
            transferred = true
            return Header(payload: .disk(url), size: data.count, owner: self)
        }
    }

    private func release(_ payload: Header.Payload, size: Int) {
        if case .disk(let url) = payload { try? FileManager.default.removeItem(at: url) }
        lock.lock()
        switch payload {
        case .memory: memoryBytes -= size
        case .disk: diskBytes -= size
        }
        let drained = closed && diskBytes == 0
        lock.unlock()
        if drained { removeEmptySession() }
    }

    func close() {
        lock.lock(); closed = true; let drained = diskBytes == 0; lock.unlock()
        if drained { removeEmptySession() }
    }
    private func removeEmptySession() {
        // removeItem recursively deletes directories, so use POSIX rmdir's
        // empty-only semantics while concurrent owners may still be writing.
        _ = sessionDirectory.path.withCString { rmdir($0) }
    }
    deinit { removeEmptySession() }
}
