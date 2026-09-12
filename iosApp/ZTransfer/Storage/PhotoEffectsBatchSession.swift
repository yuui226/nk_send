import Foundation
import Combine

struct IOSPhotoEffectAsset: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    // A worker keeps its input alive even after the workbench releases the selection.
    private let inputFiles: PhotoEffectsInputFiles?

    init(id: String, url: URL, displayName: String, inputFiles: PhotoEffectsInputFiles? = nil) {
        self.id = id; self.url = url; self.displayName = displayName; self.inputFiles = inputFiles
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.displayName == rhs.displayName
    }
}

enum IOSPhotoEffectsBatchStatus: Equatable, Sendable {
    case idle
    case generating(completed: Int, total: Int)
    case finished(saved: Int, failed: Int)
}

/// The selected set stays fixed during a batch. Failures and successes refer to real asset IDs,
/// while a generation token rejects late callbacks after the workbench has been closed.
@MainActor
final class PhotoEffectsBatchSession: ObservableObject {
    @Published private(set) var assets: [IOSPhotoEffectAsset] = []
    @Published private(set) var previewIndex = 0
    @Published private(set) var status: IOSPhotoEffectsBatchStatus = .idle
    @Published private(set) var failedAssets: [IOSPhotoEffectAsset] = []
    @Published private(set) var completedAssets: [IOSPhotoEffectAsset] = []

    let photosPublisher = PhotoEffectsPhotosPublisher()
    let artifacts = PhotoEffectsArtifactSink()
    private let coordinator: PhotoEffectsBatchCoordinator
    private var generationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var successfulIDs = Set<String>()
    private var failedIDs = Set<String>()
    private var lastOperation: (@Sendable (IOSPhotoEffectAsset) async throws -> Bool)?

    init(coordinator: PhotoEffectsBatchCoordinator = PhotoEffectsBatchCoordinator()) {
        self.coordinator = coordinator
    }

    var selectedCount: Int { assets.count }
    var currentAsset: IOSPhotoEffectAsset? { assets.indices.contains(previewIndex) ? assets[previewIndex] : nil }
    var isGenerating: Bool {
        if case .generating = status { return true }
        return false
    }
    var canRetryFailed: Bool { !failedAssets.isEmpty && !isGenerating && lastOperation != nil }

    var generateButtonTitle: String {
        switch status {
        case .idle: return "生成并保存"
        case let .generating(completed, total): return "生成中 \(completed)/\(total)"
        case let .finished(saved, failed):
            return failed == 0 ? "已完成 \(saved) 张" : "完成 \(saved) 张，失败 \(failed) 张"
        }
    }

    @discardableResult
    func replaceSelection(_ values: [IOSPhotoEffectAsset]) -> Bool {
        guard !isGenerating else { return false }
        var seen = Set<String>()
        assets = values.filter { seen.insert($0.id).inserted }
        previewIndex = 0
        resetResults()
        return true
    }

    func removeCurrent() {
        guard !isGenerating, assets.indices.contains(previewIndex) else { return }
        assets.remove(at: previewIndex)
        previewIndex = min(previewIndex, max(assets.count - 1, 0))
        resetResults()
    }

    func movePreview(by offset: Int) {
        guard assets.count > 1 else { return }
        let step = offset % assets.count
        previewIndex = (previewIndex + step + assets.count) % assets.count
    }

    func setPreviewIndex(_ value: Int) {
        guard !assets.isEmpty else { previewIndex = 0; return }
        previewIndex = min(max(value, 0), assets.count - 1)
    }

    @discardableResult
    func generateAndSave(_ operation: @escaping @Sendable (IOSPhotoEffectAsset) async throws -> Bool) -> Task<Void, Never>? {
        guard !assets.isEmpty, !isGenerating else { return nil }
        resetResults()
        return startGeneration(items: assets, operation: operation)
    }

    @discardableResult
    func retryFailed() -> Task<Void, Never>? {
        guard canRetryFailed, let operation = lastOperation else { return nil }
        let retry = failedAssets
        failedIDs.removeAll()
        failedAssets = []
        return startGeneration(items: retry, operation: operation)
    }

    /// Lifecycle teardown only. The product UI deliberately has no stop button.
    func cancelForDismissal() {
        generation &+= 1
        generationTask?.cancel()
        generationTask = nil
        lastOperation = nil
        status = .idle
    }

    private func resetResults() {
        generation &+= 1
        successfulIDs.removeAll()
        failedIDs.removeAll()
        failedAssets = []
        completedAssets = []
        lastOperation = nil
        status = .idle
    }

    private func record(_ asset: IOSPhotoEffectAsset, saved: Bool, token: UInt64) {
        guard generation == token, isGenerating else { return }
        if saved { successfulIDs.insert(asset.id); failedIDs.remove(asset.id) }
        else { failedIDs.insert(asset.id) }
        completedAssets = assets.filter { successfulIDs.contains($0.id) }
        failedAssets = assets.filter { failedIDs.contains($0.id) }
    }

    private func publish(_ progress: IOSPhotoEffectsBatchProgress, token: UInt64) {
        guard generation == token, isGenerating else { return }
        status = .generating(completed: progress.completed, total: progress.total)
    }

    private func finish(token: UInt64) {
        guard generation == token, isGenerating else { return }
        status = .finished(saved: completedAssets.count, failed: failedAssets.count)
        generationTask = nil
    }

    private func cancelled(token: UInt64) {
        guard generation == token else { return }
        generationTask = nil
        lastOperation = nil
        status = .idle
    }

    private func startGeneration(
        items: [IOSPhotoEffectAsset],
        operation: @escaping @Sendable (IOSPhotoEffectAsset) async throws -> Bool
    ) -> Task<Void, Never> {
        generation &+= 1
        let token = generation
        let coordinator = coordinator
        lastOperation = operation
        status = .generating(completed: 0, total: items.count)
        let task = Task { [weak self] in
            do {
                _ = try await coordinator.process(items, onProgress: { [weak self] progress in
                    await self?.publish(progress, token: token)
                }, generateAndSave: { [weak self] asset in
                    let saved: Bool
                    do { saved = try await operation(asset) }
                    catch is CancellationError { throw CancellationError() }
                    catch { saved = false }
                    await self?.record(asset, saved: saved, token: token)
                    return saved
                })
                try Task.checkCancellation()
                self?.finish(token: token)
            } catch {
                self?.cancelled(token: token)
            }
        }
        generationTask = task
        return task
    }

    deinit { generationTask?.cancel() }
}
