import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Owns only the private directory created for one selection. Assets retain it through preview
/// and batch work; releasing that selection never removes an external original.
final class PhotoEffectsInputFiles: @unchecked Sendable {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-photo-inputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func copy(_ source: URL, assetID: String?, displayName: String?, fallbackExtension: String) throws -> IOSPhotoEffectAsset {
        guard source.isFileURL,
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PhotoEffectsPickerError.missingFile
        }
        let ext = source.pathExtension.isEmpty ? fallbackExtension : source.pathExtension
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return IOSPhotoEffectAsset(id: assetID ?? destination.lastPathComponent, url: destination,
            displayName: displayName ?? source.lastPathComponent, inputFiles: self)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum PhotoEffectsPickerResult {
    case cancelled
    case selected([IOSPhotoEffectAsset], failedCount: Int)
}

private enum PhotoEffectsPickerError: Error { case unsupportedType, missingFile }

/// A provider URL is valid only during its callback. Copy there, and keep the private directory
/// alive if cancellation races a callback already doing IO. Each continuation is resumed once.
final class PhotoEffectsPickerLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IOSPhotoEffectAsset, Error>?
    private var progress: Progress?
    private var finished = false
    private var cancelled = false

    func load(_ provider: NSItemProvider, into files: PhotoEffectsInputFiles,
              assetID: String?) async throws -> IOSPhotoEffectAsset {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            throw PhotoEffectsPickerError.unsupportedType
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                let pending = provider.loadFileRepresentation(forTypeIdentifier: type) { [self, files] url, error in
                    guard canCopy else { return }
                    if let error { finish(.failure(error)); return }
                    guard let url else { finish(.failure(PhotoEffectsPickerError.missingFile)); return }
                    do {
                        let asset = try files.copy(url, assetID: assetID, displayName: provider.suggestedName,
                            fallbackExtension: UTType(type)?.preferredFilenameExtension ?? "jpg")
                        finish(.success(asset))
                    } catch { finish(.failure(error)) }
                }
                install(pending)
            }
        } onCancel: { self.cancel() }
    }

    private var canCopy: Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished
    }

    private func install(_ value: CheckedContinuation<IOSPhotoEffectAsset, Error>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock(); value.resume(throwing: CancellationError()); return false
        }
        continuation = value
        lock.unlock()
        return true
    }

    private func install(_ value: Progress) {
        lock.lock()
        let shouldCancel = cancelled
        if !finished { progress = value }
        lock.unlock()
        if shouldCancel { value.cancel() }
    }

    private func finish(_ result: Result<IOSPhotoEffectAsset, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = continuation
        continuation = nil; progress = nil
        lock.unlock()
        callback?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; cancelled = true
        let callback = continuation, pending = progress
        continuation = nil; progress = nil
        lock.unlock()
        callback?.resume(throwing: CancellationError())
        pending?.cancel()
    }
}

/// System photo picker bridge for the workbench. A zero selection limit keeps the picker useful
/// for a batch of any size; the session still de-duplicates identities before rendering.
@MainActor
struct PhotoEffectsPicker: UIViewControllerRepresentable {
    let onSelection: (PhotoEffectsPickerResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: PHPickerViewController, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelection: (PhotoEffectsPickerResult) -> Void
        private var task: Task<Void, Never>?
        private var generation = UUID()

        init(onSelection: @escaping (PhotoEffectsPickerResult) -> Void) {
            self.onSelection = onSelection
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            cancel()
            guard !results.isEmpty else {
                onSelection(.cancelled)
                return
            }
            let token = generation
            task = Task { [weak self] in
                do {
                    let files = try PhotoEffectsInputFiles()
                    var assets: [IOSPhotoEffectAsset] = []
                    var seen = Set<String>()
                    var failures = 0
                    for result in results {
                        try Task.checkCancellation()
                        if let id = result.assetIdentifier, !seen.insert(id).inserted { continue }
                        do {
                            let asset = try await PhotoEffectsPickerLoad().load(result.itemProvider, into: files,
                                assetID: result.assetIdentifier)
                            assets.append(asset)
                        } catch is CancellationError { throw CancellationError() }
                        catch { failures += 1 }
                    }
                    try Task.checkCancellation()
                    self?.finish(.selected(assets, failedCount: failures), token: token)
                } catch is CancellationError {
                    // The system sheet was dismissed or a newer selection superseded this one.
                } catch {
                    self?.finish(.selected([], failedCount: results.count), token: token)
                }
            }
        }

        func cancel() {
            generation = UUID()
            task?.cancel(); task = nil
        }

        private func finish(_ result: PhotoEffectsPickerResult, token: UUID) {
            guard generation == token else { return }
            task = nil
            onSelection(result)
        }

        deinit { task?.cancel() }
    }
}

/// The preview host supplies the rendered image, so this pager remains independent of the
/// decoder and filter kernel. Swiping updates the same index used by the session and its status.
@MainActor
struct PhotoEffectsPreviewPager<Content: View>: View {
    @ObservedObject var session: PhotoEffectsBatchSession
    @ViewBuilder let content: (IOSPhotoEffectAsset) -> Content

    var body: some View {
        TabView(selection: Binding(get: { session.previewIndex }, set: session.setPreviewIndex)) {
            ForEach(Array(session.assets.enumerated()), id: \.element.id) { index, asset in
                content(asset)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
    }
}
