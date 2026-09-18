import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// NikonCamera's paired-STA direct-read route. It uses compact filename/date
/// indexes first, then bounded headers; full originals are never catalog probes.
actor STAObjectReader {
    private let session: PTPSession
    private let operations: Set<UInt16>
    private var names: [UInt32: String] = [:]
    private var dates: [UInt32: String] = [:]
    private var datesLoaded = false
    private var files: [UInt32: CameraFile] = [:]
    private var anchors: [UInt32: STAMediaMetadata.Anchor] = [:]
    private var sessionAnchor: STAMediaMetadata.Anchor?
    private var nameValueSupported: Bool?
    private var namesLoaded = false
    private var embeddedNameAvailable: [String: Bool] = [:]
    private var prefixes: [UInt32: Data] = [:]
    private var prefixOrder: [UInt32] = []
    private var thumbnails: [UInt32: Data] = [:]
    private var thumbnailOrder: [UInt32] = []
    private var thumbnailBytes = 0
    private var noThumbnail = Set<UInt32>()
    private var rawPreviews: [UInt32: [STAMediaMetadata.Preview]] = [:]
    private var rawIndexedHandles = Set<UInt32>()
    private var mpfPreviews: [UInt32: [STAMediaMetadata.Preview]] = [:]
    private var previewSupport: [UInt16: Bool] = [:]
    private var rawThumbnailHint: STAMediaMetadata.Preview?
    private static let rawProbeSizes = [240, 256, 512, 1024, 2048, 4096, 8192, 16384].map { $0 * 1024 }

    init(session: PTPSession, operations: Set<UInt16>) { self.session = session; self.operations = operations }

    func prepare(groups: [(storage: UInt32, handles: [UInt32])]) async throws {
        if !namesLoaded {
            namesLoaded = true
            if operations.contains(0x9805) {
                let result = try await command(0x9805, [.max, 0, 0xDC07, 0, 0])
                if result.code == PTPConstants.responseOK { names.merge(STAMediaMetadata.fileNamePropertyList(result.data)) { _, new in new } }
            }
        }
        try await refreshDates(storageIDs: groups.map(\.storage), force: false)
        for group in groups where group.storage == .max || anchors[group.storage] == nil {
            guard let handle = group.handles.first(where: {
                let ext = STAMediaMetadata.extensionFromHandle($0)
                return ext == ".jpg" || ext == ".nef"
            }) else { continue }
            do { _ = try await readHeader(handle: handle, storage: group.storage) }
            catch PTPSessionError.responseCode { continue }
            catch PTPSessionError.invalidResponse { continue }
            if let prefix = prefixes[handle], let file = STAMediaMetadata.makerFileNumber(prefix) {
                let anchor = STAMediaMetadata.Anchor(sequence: handle & 0xFFFFFF, file: file)
                sessionAnchor = anchor
                if group.storage != .max { anchors[group.storage] = anchor }
            }
        }
    }

    func refreshDates(storageIDs: [UInt32], force: Bool = true) async throws {
        // Android loads this compact index once per session during catalog
        // setup. Only the new-object resolver explicitly forces a refresh.
        if !force {
            guard !datesLoaded else { return }
            datesLoaded = true
        } else {
            datesLoaded = true
        }
        guard operations.contains(PTPConstants.getObjectsMetadata) else { return }
        for storage in Set(storageIDs).sorted() {
            let result = try await command(PTPConstants.getObjectsMetadata, [storage, 0, 0])
            if result.code == PTPConstants.responseOK { dates.merge(STAMediaMetadata.indexedDates(result.data)) { _, new in new } }
        }
    }

    func file(handle: UInt32, storage: UInt32) async throws -> CameraFile {
        if let file = files[handle] { return file }
        if let ext = STAMediaMetadata.extensionFromHandle(handle), let date = dates[handle] {
            let size = try await objectSize(handle)
            let anchor = storage == .max ? sessionAnchor : anchors[storage]
            let derived = anchor.flatMap { STAMediaMetadata.derive($0, handle: handle) }
                .flatMap { STAMediaMetadata.defaultFileName($0, extension: ext) }
            if let name = names[handle] ?? derived {
                let file = makeFile(handle, storage, size, name, date)
                files[handle] = file
                return file
            }
        }
        return try await readHeader(handle: handle, storage: storage)
    }

    func thumbnail(handle: UInt32) async throws -> Data {
        if let cached = thumbnails[handle] { return cached }
        if noThumbnail.contains(handle) { return Data() }
        // NikonCamera.getThumbnail chooses its route from the catalog cache.
        // An unknown handle reads only the header on this request, not a RAW
        // probe as well. Catalogued NEFs take the lazy RAW route below.
        guard let file = files[handle] else {
            do { _ = try await readHeader(handle: handle, storage: .max) }
            catch PTPSessionError.responseCode { }
            catch PTPSessionError.invalidResponse { }
            if let cached = thumbnails[handle] { return cached }
            noThumbnail.insert(handle)
            return Data()
        }
        let bytes: Data?
        switch file.fileExtension {
        case ".nef": bytes = try await rawThumbnail(file)
        case ".mov", ".mp4":
            _ = try await readHeader(handle: handle, storage: file.storageID)
            if let thumbnail = thumbnails[handle] { return thumbnail }
            let prefix = try await readPrefix(handle, target: min(Int(clamping: file.size), 8 * 1024 * 1024))
            if let range = STAMediaMetadata.largestEmbeddedJPEG(prefix) { bytes = slice(prefix, range) }
            else {
                bytes = await Self.videoFrame(prefix, extension: file.fileExtension)
                try Task.checkCancellation()
                if bytes == nil && prefix.count == min(Int(clamping: file.size), 8 * 1024 * 1024) { noThumbnail.insert(handle) }
            }
        default:
            _ = try await readHeader(handle: handle, storage: file.storageID)
            bytes = thumbnails[handle]
            if bytes == nil { noThumbnail.insert(handle) }
        }
        if let bytes { rememberThumbnail(handle, bytes); return bytes }
        return Data()
    }

    func preview(handle: UInt32) async throws -> Data {
        for operation in [PTPConstants.getFHDPicture, PTPConstants.getLargeThumb] {
            if previewSupport[operation] == false || (operation == PTPConstants.getLargeThumb && !operations.contains(operation)) { continue }
            var retries = 2
            while true {
                let result = try await command(operation, [handle])
                if result.code == PTPConstants.responseOK, dimensions(result.data) != nil {
                    previewSupport[operation] = true
                    return result.data
                }
                if result.code == PTPConstants.deviceBusy && retries > 0 {
                    retries -= 1; try await Task.sleep(nanoseconds: 160_000_000); continue
                }
                if result.code == PTPConstants.operationNotSupported || result.code == 0x200F { previewSupport[operation] = false }
                break
            }
        }
        let file = try await file(handle: handle, storage: files[handle]?.storageID ?? .max)
        if file.fileExtension == ".jpg" {
            _ = try await readHeader(handle: handle, storage: file.storageID, requirePreview: true)
            for reference in mpfPreviews[handle] ?? [] {
                let data = try await partial(handle, offset: reference.offset, length: reference.length)
                if completeJPEG(data, length: reference.length), dimensions(data) != nil { return data }
            }
        } else if file.fileExtension == ".nef", let data = try await rawPreview(file) { return data }
        return Data()
    }

    /// Header-only EXIF read used by the Android direct STA path. The reader
    /// grows its bounded prefix cache instead of issuing a fresh full-object
    /// request for every metadata visit.
    func exifHeader(handle: UInt32, length: Int) async throws -> Data {
        let storage = files[handle]?.storageID ?? .max
        _ = try await file(handle: handle, storage: storage)
        return try await readPrefix(handle, target: length)
    }

    func invalidate(handle: UInt32) {
        files.removeValue(forKey: handle); names.removeValue(forKey: handle); dates.removeValue(forKey: handle)
        prefixes.removeValue(forKey: handle); prefixOrder.removeAll { $0 == handle }
        thumbnailBytes -= thumbnails.removeValue(forKey: handle)?.count ?? 0
        thumbnailOrder.removeAll { $0 == handle }; noThumbnail.remove(handle)
        rawPreviews.removeValue(forKey: handle); rawIndexedHandles.remove(handle); mpfPreviews.removeValue(forKey: handle)
    }

    /// Decode rejection is not a successful cached image. Keep catalog data
    /// and preview indexes, but let the next attempt read the camera again.
    func discardThumbnail(handle: UInt32) {
        thumbnailBytes -= thumbnails.removeValue(forKey: handle)?.count ?? 0
        thumbnailOrder.removeAll { $0 == handle }
        noThumbnail.remove(handle)
    }

    private func readHeader(handle: UInt32, storage: UInt32, requirePreview: Bool = false) async throws -> CameraFile {
        let protocolName = try await originalName(handle)
        let size: UInt64
        if let cached = files[handle] { size = cached.size } else { size = try await objectSize(handle) }
        let maximum = min(Int(clamping: size), 128 * 1024)
        let shortJPEG = !requirePreview && STAMediaMetadata.extensionFromHandle(handle) == ".jpg" && maximum > 68 * 1024
        var header = try await readPrefix(handle, target: shortJPEG ? 68 * 1024 : maximum)
        if shortJPEG && STAMediaMetadata.exifBase(header) == nil { header = try await readPrefix(handle, target: maximum) }
        let ext = STAMediaMetadata.detectedExtension(header)
        let embedded = protocolName == nil && embeddedNameAvailable[ext] != false ? STAMediaMetadata.embeddedFileName(header, extension: ext) : nil
        if protocolName == nil && embeddedNameAvailable[ext] == nil { embeddedNameAvailable[ext] = embedded != nil }
        let maker = STAMediaMetadata.makerFileNumber(header)
        if let maker { sessionAnchor = STAMediaMetadata.Anchor(sequence: handle & 0xFFFFFF, file: maker) }
        let anchor = storage == .max ? sessionAnchor : anchors[storage]
        let fileInfo = maker ?? anchor.flatMap { STAMediaMetadata.derive($0, handle: handle) }
        let derived = fileInfo.flatMap { STAMediaMetadata.defaultFileName($0, extension: ext) }
        let original = protocolName ?? embedded ?? derived
        if let original { names[handle] = original }
        let finalExtension = ext == ".bin" ? original.map { "." + ($0 as NSString).pathExtension.lowercased() } ?? ext : ext
        var date = dates[handle]
        var thumbnail: Data?
        if ext == ".jpg" || ext == ".nef" {
            let metadata = STAMediaMetadata.tiffHeader(header)
            date = metadata.captureDate ?? date
            if ext == ".nef" {
                rawPreviews[handle] = metadata.previews
                if !metadata.previews.isEmpty { rawIndexedHandles.insert(handle) }
            }
            else { mpfPreviews[handle] = STAMediaMetadata.mpfPreviews(header, objectSize: size) }
            if let reference = metadata.previews.first(where: { $0.offset + $0.length <= header.count }) { thumbnail = slice(header, reference) }
            if thumbnail == nil, let range = STAMediaMetadata.largestEmbeddedJPEG(header) { thumbnail = slice(header, range) }
            // Android's exact order is IFD range -> marker scan ->
            // ExifInterface(File).thumbnailBytes, including undecodable ranges.
            if ext == ".nef", thumbnail == nil { thumbnail = STAMediaMetadata.nefExifThumbnail(header) }
        } else if ext == ".mov" || ext == ".mp4" {
            date = STAMediaMetadata.videoDate(header) ?? date
            if date == nil && size > header.count {
                let length = min(Int(clamping: size), 256 * 1024)
                let tail = try await partial(handle, offset: Int(clamping: size) - length, length: length)
                date = STAMediaMetadata.videoDate(tail)
            }
            if let reference = STAMediaMetadata.largestEmbeddedJPEG(header) { thumbnail = slice(header, reference) }
        }
        let dateStem = date.map { String($0.filter(\.isNumber).prefix(14)) + "_" } ?? ""
        let fallback = "ZTransfer_" + dateStem + String(format: "%08X", handle) + finalExtension
        let name = original?.lowercased().hasSuffix(finalExtension) == true ? original! : fallback
        let file = makeFile(handle, storage, size, name, date)
        files[handle] = file
        if let thumbnail { rememberThumbnail(handle, thumbnail) }
        else if ext == ".jpg" { noThumbnail.insert(handle) }
        return file
    }

    private func originalName(_ handle: UInt32) async throws -> String? {
        if let name = names[handle] { return name }
        guard nameValueSupported != false else { return nil }
        guard operations.contains(0x9803) else { nameValueSupported = false; return nil }
        let result = try await command(0x9803, [handle, 0xDC07])
        var reader = PTPDataReader(result.data)
        let name = result.code == PTPConstants.responseOK ? reader.readPTPString(requireNullTerminator: true).flatMap(STAMediaMetadata.cameraBaseFileName) : nil
        nameValueSupported = name != nil
        if let name { names[handle] = name }
        return name
    }
    private func objectSize(_ handle: UInt32) async throws -> UInt64 {
        let response = try await session.execute(operation: PTPConstants.getObjectSize, parameters: [handle], timeoutNanoseconds: 60_000_000_000)
        var reader = PTPDataReader(response.data)
        guard let size = reader.readUInt64(), size > 0, size <= UInt64(Int64.max) else { throw PTPSessionError.invalidResponse }
        return size
    }
    private func command(_ operation: UInt16, _ parameters: [UInt32]) async throws -> PTPResponse {
        try await session.executeResponse(operation: operation, parameters: parameters, timeoutNanoseconds: 60_000_000_000)
    }
    private func partial(_ handle: UInt32, offset: Int, length: Int) async throws -> Data {
        let reply = try await partialResponse(handle, offset: offset, length: length)
        guard reply.code == PTPConstants.responseOK else { throw PTPSessionError.responseCode(reply.code) }
        guard !reply.data.isEmpty else { throw PTPSessionError.invalidResponse }
        return reply.data
    }
    private func partialResponse(_ handle: UInt32, offset: Int, length: Int) async throws -> PTPResponse {
        try await command(PTPConstants.getPartialObjectEx,
            [handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(length), 0])
    }
    /// NikonCamera.readStaDirectPartialInternal returns null for a complete
    /// negative/empty response. RAW hints and indexed ranges are probes: a
    /// rejected range must not prevent the prefix parser from finding this
    /// NEF's actual JPEG. Transport/malformed-response/cancellation errors still
    /// propagate, because they do not establish a completed PTP transaction.
    private func rawPartial(_ handle: UInt32, offset: Int, length: Int) async throws -> Data? {
        guard length > 0 else { return nil }
        let reply = try await partialResponse(handle, offset: offset, length: length)
        return reply.code == PTPConstants.responseOK && !reply.data.isEmpty ? reply.data : nil
    }
    private func readPrefix(_ handle: UInt32, target: Int) async throws -> Data {
        let existing = prefixes[handle] ?? Data()
        if existing.count >= target { return existing }
        let suffix = try await partial(handle, offset: existing.count, length: target - existing.count)
        let prefix = existing + suffix
        rememberPrefix(handle, prefix)
        return prefix
    }
    private func rememberPrefix(_ handle: UInt32, _ data: Data) {
        let retainedLength = min(data.count, 512 * 1024)
        // Match Android's check-before-copy order. Once the retained 512 KiB
        // cap is reached, later 1/2/4/8/16 MiB RAW probe steps must not copy
        // another 512 KiB merely to discover that the cache cannot grow.
        guard retainedLength > (prefixes[handle]?.count ?? 0) else { return }
        let retained = retainedLength == data.count ? data : Data(data.prefix(retainedLength))
        if prefixes[handle] == nil { prefixOrder.append(handle) }
        prefixes[handle] = retained
        while prefixOrder.count > 4 { prefixes.removeValue(forKey: prefixOrder.removeFirst()) }
    }
    private func rememberThumbnail(_ handle: UInt32, _ data: Data) {
        thumbnailBytes -= thumbnails.removeValue(forKey: handle)?.count ?? 0
        thumbnailOrder.removeAll { $0 == handle }
        guard data.count <= 4 * 1024 * 1024 else { return }
        thumbnails[handle] = data; thumbnailOrder.append(handle); thumbnailBytes += data.count
        while thumbnailBytes > 4 * 1024 * 1024 && thumbnailOrder.count > 1 {
            thumbnailBytes -= thumbnails.removeValue(forKey: thumbnailOrder.removeFirst())?.count ?? 0
        }
    }
    private func makeFile(_ handle: UInt32, _ storage: UInt32, _ size: UInt64, _ name: String, _ date: String?) -> CameraFile {
        let format: UInt16
        switch (name as NSString).pathExtension.lowercased() { case "jpg", "jpeg": format = 0x3801; case "nef": format = 0xB103; case "mov": format = 0x300D; case "mp4": format = 0x300E; default: format = 0x3000 }
        return CameraFile(id: handle, storageID: storage, format: format, size: size, fileName: name, captureDate: date, isProtected: false)
    }
    private func slice(_ data: Data, _ reference: STAMediaMetadata.Preview) -> Data? {
        guard reference.offset >= 0, reference.offset + reference.length <= data.count else { return nil }
        return data.subdata(in: reference.offset..<(reference.offset + reference.length))
    }
    private func completeJPEG(_ data: Data, length: Int) -> Bool {
        data.count == length && data.starts(with: [255, 216]) && data.suffix(2) == Data([255, 217])
    }
    private func dimensions(_ data: Data) -> Int? {
        guard data.starts(with: [255, 216]), let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0 && height > 0 else { return nil }
        return max(width, height)
    }

    /// Android extractVideoFrame: closest sync frame at zero from the same
    /// bounded 8 MiB prefix, JPEG quality 86, temporary file always removed.
    private static func videoFrame(_ bytes: Data, extension ext: String) async -> Data? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sta_video_" + UUID().uuidString)
            .appendingPathExtension(String(ext.dropFirst()))
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try bytes.write(to: file)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            let image = try await generator.image(at: .zero).image
            try Task.checkCancellation()
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        } catch { return nil }
    }

    /// Literal thumbnail state machine from readStaDirectRawThumbnailInternal.
    /// Keep it separate from full-screen preview: Android has separate readers
    /// with different candidate selection, completeness checks and cache writes.
    private func rawThumbnail(_ file: CameraFile) async throws -> Data? {
        func readReference(_ reference: STAMediaMetadata.Preview) async throws -> Data? {
            guard let bytes = try await rawPartial(file.id, offset: reference.offset, length: reference.length),
                  bytes.starts(with: [255, 216]) else { return nil }
            return bytes
        }
        // A cached reference is authoritative for the route, not the outcome:
        // null is returned directly and remains retryable on the next request.
        // Do not update the session hint on this cached-reference branch.
        if let reference = rawPreviews[file.id]?.last { return try await readReference(reference) }
        if let hint = rawThumbnailHint, UInt64(hint.offset) < file.size {
            let available = Int(clamping: file.size) - hint.offset
            let maximum = min(available, max(192 * 1024, hint.length + 64 * 1024))
            let initial = min(maximum, max(128 * 1024, hint.length + 16 * 1024))
            if var bytes = try await rawPartial(file.id, offset: hint.offset, length: initial) {
                if STAMediaMetadata.largestEmbeddedJPEG(bytes) == nil && bytes.count < maximum,
                   let tail = try await rawPartial(file.id, offset: hint.offset + bytes.count, length: maximum - bytes.count) {
                    bytes += tail
                }
                if let range = STAMediaMetadata.largestEmbeddedJPEG(bytes), let image = slice(bytes, range) {
                    let absolute = STAMediaMetadata.Preview(offset: hint.offset + range.offset, length: range.length)
                    rawThumbnailHint = absolute; rawPreviews[file.id] = [absolute]
                    return image
                }
            }
        }
        let maximum = min(Int(clamping: file.size), 16 * 1024 * 1024)
        guard maximum > 0 else { return nil }
        var accumulated = Data((prefixes[file.id] ?? Data()).prefix(maximum))
        var foundReference = false
        for step in Self.rawProbeSizes {
            let target = min(step, maximum)
            if target > accumulated.count {
                guard let chunk = try await rawPartial(file.id, offset: accumulated.count, length: target - accumulated.count) else { break }
                accumulated.append(chunk.prefix(maximum - accumulated.count))
            }
            rememberPrefix(file.id, accumulated)
            let references = STAMediaMetadata.tiffHeader(accumulated).previews
            if let reference = references.last {
                foundReference = true
                if let bytes = try await readReference(reference) {
                    rawPreviews[file.id] = references; rawIndexedHandles.insert(file.id)
                    rawThumbnailHint = reference
                    return bytes
                }
            }
            // Android does not call ExifInterface during progressive probing.
            if let range = STAMediaMetadata.largestEmbeddedJPEG(accumulated), let bytes = slice(accumulated, range) {
                rawPreviews[file.id] = [range]; rawThumbnailHint = range
                return bytes
            }
            if accumulated.count >= maximum || accumulated.count < target { break }
        }
        if !foundReference && accumulated.count >= maximum { noThumbnail.insert(file.id) }
        return nil
    }

    private func rawPreview(_ file: CameraFile) async throws -> Data? {
        func readIndexed(_ references: [STAMediaMetadata.Preview]) async throws -> Data? {
            let ordered = references.sorted { $0.length < $1.length }
            let plausible = ordered.filter { $0.length >= 512 * 1024 }
            let candidates = plausible.isEmpty ? ordered : plausible
            var last: Data?
            for reference in candidates {
                guard let bytes = try await rawPartial(file.id, offset: reference.offset, length: reference.length) else { continue }
                if completeJPEG(bytes, length: reference.length), let edge = dimensions(bytes) {
                    last = bytes
                    if edge >= 1600 { return bytes }
                }
            }
            return last
        }
        if rawIndexedHandles.contains(file.id),
           let refs = rawPreviews[file.id], !refs.isEmpty, let bytes = try await readIndexed(refs) { return bytes }
        let maximum = min(Int(clamping: file.size), 16 * 1024 * 1024)
        guard maximum > 0 else { return nil }
        var accumulated = Data((prefixes[file.id] ?? Data()).prefix(maximum))
        var bestScanned: STAMediaMetadata.Preview?
        for step in Self.rawProbeSizes {
            let target = min(step, maximum)
            if target > accumulated.count {
                guard let chunk = try await rawPartial(file.id, offset: accumulated.count, length: target - accumulated.count) else { break }
                accumulated.append(chunk.prefix(maximum - accumulated.count))
            }
            rememberPrefix(file.id, accumulated)
            let metadata = STAMediaMetadata.tiffHeader(accumulated)
            let references = metadata.previews
            if !references.isEmpty {
                rawPreviews[file.id] = references; rawIndexedHandles.insert(file.id)
                if let bytes = try await readIndexed(references) { return bytes }
            }
            if let range = STAMediaMetadata.largestEmbeddedJPEG(accumulated) {
                if range.length > (bestScanned?.length ?? 0) { bestScanned = range }
            }
            if accumulated.count >= maximum || accumulated.count < target { break }
        }
        return bestScanned.flatMap { slice(accumulated, $0) }
    }
}
