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
    @Published private(set) var failedAssets: [IOSPhotoEffectAsset] = []

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

    var canRetryFailed: Bool { !failedAssets.isEmpty && !isGenerating }

    var generateButtonTitle: String {
        switch status {
        case .idle: return "生成并保存"
        case let .generating(completed, total): return "生成中 \(completed)/\(total)"
        case let .finished(saved, failed):
            return failed == 0 ? "已完成 \(saved) 张" : "完成 \(saved) 张，失败 \(failed) 张"
        }
    }

    /// Replaces the picker result as one transaction and resets the horizontal preview to the
    /// first item. Duplicate identifiers are ignored while preserving picker order.
    func replaceSelection(_ values: [IOSPhotoEffectAsset]) {
        var seen = Set<String>()
        assets = values.filter { seen.insert($0.id).inserted }
        previewIndex = 0
        failedAssets = []
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

    func setPreviewIndex(_ value: Int) {
        guard !assets.isEmpty else { previewIndex = 0; return }
        previewIndex = min(max(value, 0), assets.count - 1)
    }

    /// Starts one fixed snapshot. There is intentionally no stop action in the UI; cancellation
    /// is reserved for lifecycle teardown and never reports a partial save as finished.
    func generateAndSave(_ operation: @escaping @Sendable (IOSPhotoEffectAsset) async throws -> Bool) {
        guard !assets.isEmpty, !isGenerating else { return }
        failedAssets = []
        startGeneration(items: assets, operation: operation)
    }

    func retryFailed() {
        guard canRetryFailed, let operation = lastOperation else { return }
        let retry = failedAssets
        failedAssets = []
        startGeneration(items: retry, operation: operation)
    }

    private var lastOperation: (@Sendable (IOSPhotoEffectAsset) async throws -> Bool)?

    private func startGeneration(
        items: [IOSPhotoEffectAsset],
        operation: @escaping @Sendable (IOSPhotoEffectAsset) async throws -> Bool
    ) {
        guard !items.isEmpty, !isGenerating else { return }
        let snapshot = items
        lastOperation = operation
        status = .generating(completed: 0, total: snapshot.count)
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trackedOperation: @Sendable (IOSPhotoEffectAsset) async throws -> Bool = { [weak self] asset in
                    let saved = try await operation(asset)
                    if !saved {
                        await MainActor.run { [weak self] in
                            guard let self, !self.failedAssets.contains(where: { $0.id == asset.id }) else { return }
                            self.failedAssets.append(asset)
                        }
                    }
                    return saved
                }
                let result = try await coordinator.process(snapshot, onProgress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.status = .generating(completed: progress.completed, total: progress.total)
                    }
                }, generateAndSave: trackedOperation)
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
