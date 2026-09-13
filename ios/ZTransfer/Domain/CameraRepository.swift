import Foundation

enum CameraRepositoryError: Error, Equatable, Sendable {
    case invalidDataset
}

/// Protocol-level camera catalog. It deliberately exposes only operations already used by
/// the Android NikonCamera path; UI state and transfer policy stay in higher layers.
actor CameraRepository {
    private let session: PTPSession
    private var subjectTrackingActive = false

    init(session: PTPSession) { self.session = session }

    /// Executes Android's tap-focus transaction. Nikon cameras that support
    /// StartTracking receive the tracking coordinates and then one AfDrive;
    /// unsupported bodies fall back to ChangeAfArea followed by AfDrive.
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        if subjectTrackingActive {
            _ = try? await session.execute(operation: PTPConstants.endTracking)
            subjectTrackingActive = false
        }
        do {
            _ = try await session.execute(operation: PTPConstants.startTracking,
                                          parameters: [trackingX, trackingY])
            subjectTrackingActive = true
            try await Task.sleep(nanoseconds: 80_000_000)
            let af = try await afDriveAndWait()
            return RemoteFocusResult(trackingStarted: true, polls: af.polls,
                                     timedOut: af.timedOut)
        } catch PTPSessionError.responseCode(PTPConstants.operationNotSupported) {
            _ = try await session.execute(operation: PTPConstants.changeAFArea,
                                          parameters: [focusX, focusY])
            try await Task.sleep(nanoseconds: 80_000_000)
            let af = try await afDriveAndWait()
            return RemoteFocusResult(trackingStarted: false, polls: af.polls,
                                     timedOut: af.timedOut)
        }
    }

    func endSubjectTracking() async throws {
        guard subjectTrackingActive else { return }
        do { _ = try await session.execute(operation: PTPConstants.endTracking) }
        catch PTPSessionError.responseCode(PTPConstants.operationNotSupported) {}
        catch PTPSessionError.responseCode(0xA002) {}
        subjectTrackingActive = false
    }

    private func afDriveAndWait() async throws -> (polls: Int, timedOut: Bool) {
        _ = try await session.execute(operation: PTPConstants.afDrive)
        let deadline = ContinuousClock.now + .seconds(6)
        var polls = 0
        while ContinuousClock.now < deadline {
            do {
                _ = try await session.execute(operation: PTPConstants.deviceReady,
                                              timeoutNanoseconds: 1_000_000_000)
                return (polls, false)
            } catch PTPSessionError.responseCode(PTPConstants.deviceBusy) {
                polls += 1
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        return (polls, true)
    }

    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? {
        let response = try await session.execute(operation: PTPConstants.getDevicePropDesc,
                                                 parameters: [property.rawValue])
        guard let parsed = RemotePropertyCodec.parseDescription(response.data) else { return nil }
        return RemotePropertyDescriptor(property: property, dataType: parsed.dataType,
                                        writable: parsed.writable,
                                        current: UInt64(bitPattern: parsed.current),
                                        values: parsed.values.map { UInt64(bitPattern: $0) })
    }

    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws {
        guard let encoded = RemotePropertyCodec.encode(Int64(bitPattern: value), dataType: descriptor.dataType) else {
            throw CameraRepositoryError.invalidDataset
        }
        _ = try await session.execute(operation: PTPConstants.setDevicePropValue,
                                      parameters: [descriptor.property.rawValue], data: encoded)
    }

    /// Starts Nikon Live View using the same bounded busy retry and DeviceReady
    /// poll as Android RemoteLab. A successful call means the camera is ready
    /// to accept frame requests; callers still wait for the first frame.
    func startLiveView() async throws {
        var attempts = 0
        while true {
            do {
                _ = try await session.execute(operation: PTPConstants.startLiveView)
                break
            } catch PTPSessionError.responseCode(let code)
                where (code == PTPConstants.deviceBusy || code == 0xA004) && attempts < 5 {
                attempts += 1
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            do {
                _ = try await session.execute(operation: PTPConstants.deviceReady,
                                              timeoutNanoseconds: 1_000_000_000)
                return
            } catch PTPSessionError.responseCode(let code) where code == PTPConstants.deviceBusy {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw PTPSessionError.timeout
    }

    func endLiveView() async {
        _ = try? await session.execute(operation: PTPConstants.endLiveView)
    }

    /// Requests one JPEG frame. Enhanced metadata frames are preferred and
    /// fall back to the standard Nikon operation when unsupported.
    func liveViewFrame(preferEnhanced: Bool = true) async throws -> Data {
        if preferEnhanced {
            do {
                let data = try await session.execute(operation: PTPConstants.getLiveViewImageEx).data
                if !data.isEmpty { return data }
            } catch PTPSessionError.responseCode(let code)
                where code == PTPConstants.operationNotSupported || code == 0xA00B {
                // Fall through to the standard frame operation.
            }
        }
        return try await session.execute(operation: PTPConstants.getLiveViewImage).data
    }

    func capturePhoto() async throws {
        _ = try await session.execute(operation: PTPConstants.captureInMedia)
    }

    func startMovieRecording() async throws -> RemoteMovieStartResult {
        let response = try await movieCommandWithBusyRetry(PTPConstants.startMovieRecording)
        var prohibitCondition: UInt32?
        if response != PTPConstants.responseOK {
            do {
                // RemoteLab.PROP_NK_MOV_PROHIBIT: read only after a failed start,
                // including bit 10 when the camera is already recording.
                let data = try await session.execute(operation: PTPConstants.getDevicePropValue,
                                                     parameters: [0xD0A4]).data
                if data.count >= 4 {
                    prohibitCondition = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                }
            } catch PTPSessionError.responseCode(_) {
                // Android keeps the start response when the optional property
                // returns a negative response. Transport errors still propagate.
            }
        }
        try Task.checkCancellation()
        return RemoteMovieStartResult(responseCode: response, prohibitCondition: prohibitCondition)
    }

    func endMovieRecording() async throws -> UInt16 {
        try await movieCommandWithBusyRetry(PTPConstants.endMovieRecording)
    }

    private func movieCommandWithBusyRetry(_ operation: UInt16) async throws -> UInt16 {
        let session = self.session
        return try await RemoteMovieCommandRetry.execute {
            do { return try await session.execute(operation: operation).code }
            catch PTPSessionError.responseCode(let response) { return response }
        }
    }

    func loadDeviceInfo() async throws -> PTPDeviceInfo {
        let result = try await session.execute(operation: PTPConstants.getDeviceInfo)
        guard let info = PTPDatasetParser.parseDeviceInfo(result.data) else { throw CameraRepositoryError.invalidDataset }
        return info
    }

    func loadStorageIDs() async throws -> [UInt32] {
        let result = try await session.execute(operation: PTPConstants.getStorageIDs)
        guard let ids = PTPDatasetParser.readStorageIDs(result.data) else { throw CameraRepositoryError.invalidDataset }
        return ids
    }

    func loadObjectHandles(storageID: UInt32 = 0xFFFFFFFF) async throws -> [UInt32] {
        let result = try await session.execute(operation: PTPConstants.getObjectHandles, parameters: [storageID, 0xFFFFFFFF, 0])
        guard let handles = PTPDatasetParser.readObjectHandles(result.data) else { throw CameraRepositoryError.invalidDataset }
        return handles
    }

    func loadObjectInfo(handle: UInt32) async throws -> CameraFile {
        let result = try await session.execute(operation: PTPConstants.getObjectInfo, parameters: [handle])
        guard let file = PTPDatasetParser.parseObjectInfo(handle: handle, result.data) else { throw CameraRepositoryError.invalidDataset }
        return file
    }

    func thumbnail(handle: UInt32) async throws -> Data {
        try await session.execute(operation: PTPConstants.getThumb, parameters: [handle]).data
    }

    /// Android's preview order: FHD picture first, then Nikon large thumb, then
    /// the standard thumbnail when the camera reports the operation unsupported.
    func preview(handle: UInt32) async throws -> Data {
        var lastError: Error?
        for operation in [PTPConstants.getFHDPicture, PTPConstants.getLargeThumb, PTPConstants.getThumb] {
            do {
                let data = try await session.execute(operation: operation, parameters: [handle]).data
                if !data.isEmpty { return data }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CameraRepositoryError.invalidDataset
    }

    func readPrefix(handle: UInt32, length: Int64) async throws -> Data {
        let count = max(0, min(length, Int64(UInt32.max)))
        let result = try await session.execute(
            operation: PTPConstants.getPartialObjectEx,
            parameters: [handle, 0, 0, UInt32(count & 0xFFFF_FFFF), UInt32(count >> 32)]
        )
        return result.data
    }

    /// PTP/IP and USB share the same serialized operation path. A temporary
    /// file is written first, then atomically moved into the destination so a
    /// cancellation or disconnect never leaves a valid-looking partial file.
    func download(handle: UInt32, size: UInt64, fileName: String, to directory: URL,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let destination = directory.appendingPathComponent(safeName, isDirectory: false)
        let temporary = destination.appendingPathExtension("ztransfer-partial")
        try? FileManager.default.removeItem(at: temporary)
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        do {
            let total: UInt64
            if size == UInt64(UInt32.max) || size == 0 {
                let sizeData = try await session.execute(operation: PTPConstants.getObjectSize, parameters: [handle]).data
                guard sizeData.count >= 8 else { throw CameraRepositoryError.invalidDataset }
                total = sizeData.readUInt64LE(at: 0)
            } else {
                total = size
            }
            guard total > 0 else { throw CameraRepositoryError.invalidDataset }
            let chunk: UInt64 = 4 * 1024 * 1024
            var offset: UInt64 = 0
            let handleForWriting = try FileHandle(forWritingTo: temporary)
            defer { try? handleForWriting.close() }
            while offset < total {
                try Task.checkCancellation()
                let request = min(chunk, total - offset)
                let result = try await session.execute(
                    operation: PTPConstants.getPartialObjectEx,
                    parameters: [handle, UInt32(offset), UInt32(offset >> 32), UInt32(request), UInt32(request >> 32)],
                    timeoutNanoseconds: 45_000_000_000
                )
                try handleForWriting.write(contentsOf: result.data)
                offset += UInt64(result.data.count)
                guard !result.data.isEmpty else { throw CameraRepositoryError.invalidDataset }
                progress?(min(1, Double(offset) / Double(total)))
            }
            try handleForWriting.close()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            progress?(1)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func loadCatalog() async throws -> [CameraFile] {
        let storageIDs = try await loadStorageIDs()
        // Android queries each physical card when two storages are present so
        // the ObjectInfo storage ID remains meaningful for the card filter.
        // The all-storage sentinel is only used when the camera exposes no
        // usable card list.
        let queries = storageIDs.isEmpty ? [UInt32.max] : storageIDs
        var handles: [UInt32] = []
        var seen = Set<UInt32>()
        for storageID in queries {
            for handle in try await loadObjectHandles(storageID: storageID) where seen.insert(handle).inserted {
                handles.append(handle)
            }
        }
        var files: [CameraFile] = []
        files.reserveCapacity(handles.count)
        for handle in handles {
            try Task.checkCancellation()
            do {
                files.append(try await loadObjectInfo(handle: handle))
            } catch is CancellationError {
                // Android propagates cancellation out of the scan. Do not let a
                // per-object fallback swallow it and keep issuing PTP commands.
                throw CancellationError()
            } catch {
                // A malformed or inaccessible individual object does not make
                // the whole Android-style catalog scan fail.
                continue
            }
        }
        return files
    }
}

private extension Data {
    func readUInt64LE(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return UInt64(self[startIndex + offset]) |
            UInt64(self[startIndex + offset + 1]) << 8 |
            UInt64(self[startIndex + offset + 2]) << 16 |
            UInt64(self[startIndex + offset + 3]) << 24 |
            UInt64(self[startIndex + offset + 4]) << 32 |
            UInt64(self[startIndex + offset + 5]) << 40 |
            UInt64(self[startIndex + offset + 6]) << 48 |
            UInt64(self[startIndex + offset + 7]) << 56
    }
}
