import Foundation
import Combine

struct IOSPhotoEffectAsset: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let displayName: String
}

enum IOSPhotoEffectsBatchStatus: Equatable, Sendable {
    case idle
    case generating(completed: Int, total: Int)
    case finished(saved: Int, failed: Int)
}

/// Main-actor state for the workbench. It deliberately separates the selected asset snapshot
/// from generation progress: the selection count never shrinks while a batch is running.
@MainActor
final class PhotoEffectsBatchSession: ObservableObject {
    @Published private(set) var assets: [IOSPhotoEffectAsset] = []
    @Published private(set) var previewIndex = 0
    @Published private(set) var status: IOSPhotoEffectsBatchStatus = .idle

    private let coordinator: PhotoEffectsBatchCoordinator
    private var generationTask: Task<Void, Never>?

    init(coordinator: PhotoEffectsBatchCoordinator = PhotoEffectsBatchCoordinator()) {
        self.coordinator = coordinator
    }

    var selectedCount: Int { assets.count }
    var currentAsset: IOSPhotoEffectAsset? { assets.indices.contains(previewIndex) ? assets[previewIndex] : nil }
    var isGenerating: Bool {
        if case .generating = status { return true }
        return false
    }

    /// Replaces the picker result as one transaction and resets the horizontal preview to the
    /// first item. Duplicate identifiers are ignored while preserving picker order.
    func replaceSelection(_ values: [IOSPhotoEffectAsset]) {
        var seen = Set<String>()
        assets = values.filter { seen.insert($0.id).inserted }
        previewIndex = 0
        status = .idle
    }

    func removeCurrent() {
        guard !isGenerating, assets.indices.contains(previewIndex) else { return }
        assets.remove(at: previewIndex)
        previewIndex = min(previewIndex, max(assets.count - 1, 0))
        status = .idle
    }

    func movePreview(by offset: Int) {
        guard assets.count > 1 else { return }
        previewIndex = (previewIndex + offset).positiveModulo(assets.count)
    }

    /// Starts one fixed snapshot. There is intentionally no stop action in the UI; cancellation
    /// is reserved for lifecycle teardown and never reports a partial save as finished.
    func generateAndSave(_ operation: @escaping @Sendable (IOSPhotoEffectAsset) async throws -> Bool) {
        guard !assets.isEmpty, !isGenerating else { return }
        let snapshot = assets
        status = .generating(completed: 0, total: snapshot.count)
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.process(snapshot, onProgress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.status = .generating(completed: progress.completed, total: progress.total)
                    }
                }, generateAndSave: operation)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.status = .finished(saved: result.saved, failed: result.failed)
                    self?.generationTask = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in self?.generationTask = nil }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.status = .finished(saved: 0, failed: snapshot.count)
                    self.generationTask = nil
                }
            }
        }
    }

    deinit { generationTask?.cancel() }
}

private extension Int {
    func positiveModulo(_ modulus: Int) -> Int {
        let value = self % modulus
        return value >= 0 ? value : value + modulus
    }
}
