import Foundation

enum LosslessCropProcessorError: Error, Equatable {
    case sourceMissing
    case outputExists
    case cropFailed
}

/// Android LosslessJpeg.readSource and jpeg_crop.cpp bounds. Read only the
/// JPEG header; neither source validation nor result validation needs an RGB
/// decode or a full compressed-file allocation.
enum LosslessCropInput {
    static let maximumSourceBytes = 256 * 1024 * 1024
    static let maximumPixels = 100_000_000
    static let maximumHeaderBytes = 2 * 1024 * 1024

    static func sourceHeader(from url: URL) throws -> Data {
        // URL resource values may retain a pre-transfer size. Query the file
        // each time, including when a retry reuses the same URL value.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = (values[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumSourceBytes else { throw LosslessCropProcessorError.cropFailed }
        return try header(from: url)
    }

    static func header(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count < maximumHeaderBytes {
            guard let bytes = try handle.read(upToCount: maximumHeaderBytes - result.count), !bytes.isEmpty else { break }
            result.append(bytes)
        }
        return result
    }

    static func accepts(_ source: JpegCropSource) -> Bool {
        source.width > 0 && source.height > 0 && source.width <= maximumPixels / source.height
    }
}

/// A process-wide owner, like Android cropSessionName. Every crop has a
/// separate directory, so cleanup can never delete another active task's file.
enum LosslessCropTemporaryFiles {
    static let sessionID = UUID()
    static var currentPrefix: String { ".nkcrop_crop-\(sessionID.uuidString)_" }

    static func isCurrent(_ name: String) -> Bool { name.hasPrefix(currentPrefix) }

    static func recognizes(_ name: String) -> Bool {
        // Migrate the exact broken filename produced by older iOS versions.
        if name == ".nkcrop_(UUID().uuidString).part" { return true }
        guard name.hasPrefix(".nkcrop_crop-"), name.hasSuffix(".part") else { return false }
        let ids = name.dropFirst(".nkcrop_crop-".count).dropLast(".part".count).split(separator: "_")
        return ids.count == 2 && ids.allSatisfy { UUID(uuidString: String($0)) != nil }
    }

    static func create(in directory: URL) throws -> URL {
        let staging = directory.appendingPathComponent(currentPrefix + UUID().uuidString + ".part", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }
}

/// Publishes a crop beside the transferred original while preserving the original.
/// Android checks cancellation after native work and before its non-cancellable
/// publication. Once published, callers must record the URL before checking cancellation.
enum LosslessCropProcessor {
    typealias AsyncTransform = @Sendable (URL, URL, JpegCropSource, CropRect) async throws -> Bool
    typealias Transform = @Sendable (URL, URL, JpegCropSource, CropRect) -> Bool

    static func outputURL(for source: URL, in directory: URL) -> URL {
        directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_crop.jpg")
    }

    static func processAsync(task: LosslessCropTask, sourceURL: URL, directory: URL,
                             locationFallback: PhotoCaptureLocation? = nil,
                             transform: AsyncTransform? = nil) async throws -> URL {
        try Task.checkCancellation()
        let operation = Task.detached(priority: .utility) {
            let stagingDirectory = try prepare(task: task, sourceURL: sourceURL, directory: directory)
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            let staging = stagingDirectory.appendingPathComponent("cropped.jpg")
            let succeeded: Bool
            if let transform { succeeded = try await transform(sourceURL, staging, task.source, task.rect) }
            else { succeeded = try await LosslessJpegBridge.cropAsync(input: sourceURL, output: staging,
                source: task.source, rect: task.rect, locationFallback: locationFallback) }
            return try publish(task: task, sourceURL: sourceURL, directory: directory, staging: staging,
                               succeeded: succeeded, locationFallback: locationFallback)
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    static func process(task: LosslessCropTask, sourceURL: URL, directory: URL,
                        locationFallback: PhotoCaptureLocation? = nil,
                        transform: Transform? = nil) throws -> URL {
        let stagingDirectory = try prepare(task: task, sourceURL: sourceURL, directory: directory)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let staging = stagingDirectory.appendingPathComponent("cropped.jpg")
        let succeeded = transform.map { $0(sourceURL, staging, task.source, task.rect) }
            ?? LosslessJpegBridge.crop(input: sourceURL, output: staging, source: task.source,
                                       rect: task.rect, locationFallback: locationFallback)
        return try publish(task: task, sourceURL: sourceURL, directory: directory, staging: staging,
                           succeeded: succeeded, locationFallback: locationFallback)
    }

    private static func prepare(task: LosslessCropTask, sourceURL: URL, directory: URL) throws -> URL {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw LosslessCropProcessorError.sourceMissing }
        guard let sourceData = try? LosslessCropInput.sourceHeader(from: sourceURL),
              let actual = parseJpegCropHeader(sourceData),
              actual == task.source, LosslessCropInput.accepts(actual) else { throw LosslessCropProcessorError.cropFailed }
        task.source.validate(task.rect)
        try Task.checkCancellation()
        return try LosslessCropTemporaryFiles.create(in: directory)
    }

    private static func publish(task: LosslessCropTask, sourceURL: URL, directory: URL,
                                staging: URL, succeeded: Bool, locationFallback: PhotoCaptureLocation?) throws -> URL {
        try Task.checkCancellation()
        guard succeeded,
              let header = try? LosslessCropInput.header(from: staging),
              let result = parseJpegCropHeader(header),
              result.width == task.rect.width,
              result.height == task.rect.height,
              result.orientation == task.source.orientation else {
            throw LosslessCropProcessorError.cropFailed
        }
        let sourceHeader = try LosslessCropInput.header(from: sourceURL)
        if locationFallback != nil || PhotoCaptureLocation.read(header: sourceHeader) != nil {
            guard PhotoCaptureLocation.read(header: header) != nil else { throw LosslessCropProcessorError.cropFailed }
        }
        return try OutputFileNameReservations.shared.withReservedName(outputURL(for: sourceURL, in: directory)) { output in
            try Task.checkCancellation()
            // No cancellation check after this move: the owner must first
            // retain a successful publication for retry, as Android does.
            try FileManager.default.moveItem(at: staging, to: output)
            return output
        }
    }
}
