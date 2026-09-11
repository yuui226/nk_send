import Foundation

/// Thread-safe bridge from the two batch workers back to the main-actor workbench. One artifact
/// per asset is retained; replacing it removes the previous temporary file first.
final class PhotoEffectsArtifactSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: PhotoEffectsRenderedFile] = [:]

    func replace(_ file: PhotoEffectsRenderedFile) {
        lock.lock(); defer { lock.unlock() }
        if let previous = storage.updateValue(file, forKey: file.assetID) {
            try? FileManager.default.removeItem(at: previous.url)
        }
    }

    func snapshot() -> [PhotoEffectsRenderedFile] {
        lock.lock(); defer { lock.unlock() }
        return storage.values.sorted { $0.assetID < $1.assetID }
    }

    func remove(assetID: String) {
        lock.lock(); defer { lock.unlock() }
        guard let file = storage.removeValue(forKey: assetID) else { return }
        try? FileManager.default.removeItem(at: file.url)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.values.forEach { try? FileManager.default.removeItem(at: $0.url) }
        storage.removeAll()
    }
}
