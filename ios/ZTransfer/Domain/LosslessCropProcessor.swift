import Foundation

enum LosslessCropProcessorError: Error, Equatable {
    case sourceMissing
    case outputExists
    case cropFailed
}

/// Publishes a crop beside the transferred original while preserving the original.
/// The Android worker uses `<basename>_crop.jpg` and resolves collisions in the
/// destination directory before publication.
enum LosslessCropProcessor {
    static func outputURL(for source: URL, in directory: URL) -> URL {
        directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_crop.jpg")
    }

    static func process(task: LosslessCropTask, sourceURL: URL, directory: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw LosslessCropProcessorError.sourceMissing }
        let base = outputURL(for: sourceURL, in: directory)
        let output = uniqueURL(base, directory: directory)
        guard LosslessJpegBridge.crop(input: sourceURL, output: output, source: task.source, rect: task.rect) else {
            try? FileManager.default.removeItem(at: output)
            throw LosslessCropProcessorError.cropFailed
        }
        return output
    }

    private static func uniqueURL(_ base: URL, directory: URL) -> URL {
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for n in 1...999 {
            let candidate = directory.appendingPathComponent("\(stem) (\(n)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(stem)_\(Int(Date().timeIntervalSince1970)).\(ext)")
    }
}
