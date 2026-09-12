import Foundation

/// Thread-safe bridge from the two batch workers back to the main-actor workbench. One artifact
/// per asset is retained. Files are reclaimed only after the sink, workers and any system export
/// sheet have all released their copies, so clearing a selection cannot invalidate a provider URL.
final class PhotoEffectsArtifactSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: PhotoEffectsRenderedFile] = [:]

    func replace(_ file: PhotoEffectsRenderedFile) {
        lock.lock(); defer { lock.unlock() }
        storage[file.assetID] = file
    }

    func snapshot() -> [PhotoEffectsRenderedFile] {
        lock.lock(); defer { lock.unlock() }
        return storage.values.sorted { $0.assetID < $1.assetID }
    }

    func remove(assetID: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: assetID)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
