import Foundation
import SwiftUI
import UIKit
import ZTransferShared

/// One sheet, one immutable camera generation. The connection owner forwards its EXISTING observer.
/// This bridge never consumes queue.updates and never owns/cancels the transfer worker.
@MainActor
final class OriginalQueuePageBridge: NSObject, ObservableObject, Identifiable, NativeQueuePagePlatform {
    let id = UUID()
    private let connectionID: UUID
    private let stationMode: Bool
    weak var presenter: UIViewController?
    private let queue: CameraOriginalQueue
    private let previews: CameraPreviewStore
    private let decoder = PreviewImageDecoder()
    private let previewPolicy = NativePreviewPolicy()
    private let formatter = ApplePhotoDecimalFormatter()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var imageRequests: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private var connected = false
    private(set) lazy var model = NativeQueuePageModel(connectionId: connectionID.uuidString, platform: self, stationMode: stationMode)

    init(connectionID: UUID, queue: CameraOriginalQueue, previews: CameraPreviewStore, stationMode: Bool = false) {
        self.connectionID = connectionID; self.queue = queue; self.previews = previews
        self.stationMode = stationMode
        super.init()
    }

    func setConnected(_ value: Bool) {
        guard !closed else { return }
        connected = value
        model.setConnected(value: value)
    }

    func publish(_ value: OriginalQueueSnapshot) {
        guard !closed, value.connectionID == connectionID else { return }
        let snapshot = NativeQueuePageSnapshot(connectionId: value.connectionID.uuidString,
            sequence: Int64(bitPattern: value.sequence), historyRevision: Int64(bitPattern: value.historyRevision),
            running: value.running, paused: value.paused)
        for row in value.rows {
            let stores = KotlinIntArray(size: Int32(row.storageIDs.count))
            for (index, store) in row.storageIDs.enumerated() { stores.set(index: Int32(index), value: store) }
            guard snapshot.addOriginal(taskId: row.id, handle: row.handle, size: row.size, name: row.name,
                captureDate: row.captureDate, isProtected: row.isProtected, storageIds: stores,
                destinationFolderName: row.destinationFolderName, status: row.status, downloaded: row.downloaded,
                fraction: row.fraction, bytesPerSecond: row.bytesPerSecond, error: row.error,
                elapsedMs: row.elapsedMs.map { KotlinLong(value: $0) }, downloadMBps: row.downloadMBps) else { return }
        }
        _ = model.publish(snapshot: snapshot)
    }

    func execute(command: NativeQueueCommand, taskId: Int64, excludedTaskIds: KotlinLongArray,
                 completion: NativeQueueActionCompletion) {
        guard !closed, requests.count < 32 else { completion.complete(succeeded: false); return }
        let excluded = Set((0..<Int(excludedTaskIds.size)).map { excludedTaskIds.get(index: Int32($0)) })
        let token = UUID()
        requests[token] = Task { [weak self] in
            guard let self else { completion.complete(succeeded: false); return }
            var applied = false
            defer {
                self.requests.removeValue(forKey: token)
                completion.complete(succeeded: applied)
            }
            guard !self.closed, !Task.isCancelled else { return }
            switch command {
            case .remove: applied = await self.queue.removeTask(taskId)
            case .withdraw: await self.queue.withdraw(taskId); applied = true
            case .withdrawPending: await self.queue.withdrawPending(); applied = true
            case .clear: await self.queue.clearTerminal(); applied = true
            case .retry:
                guard self.connected else { return }
                await self.queue.retry(taskId); applied = true
            case .retryAll:
                guard self.connected else { return }
                _ = await self.queue.retryFailed(excluding: excluded); applied = true
            case .start:
                guard self.connected else { return }
                await self.queue.start(); applied = true
            case .pause: await self.queue.pauseAfterCurrent(); applied = true
            default: return
            }
            // Publish the post-operation snapshot BEFORE acknowledging. clear's live read must
            // not see an older frame while the single AsyncStream observer catches up.
            let snapshot = await self.queue.snapshot()
            guard !self.closed, !Task.isCancelled else { applied = false; return }
            self.publish(snapshot)
        }
    }

    func thumbnail(file: CameraFileInfo, completion: NativeQueueThumbnailCompletion) {
        guard !closed, connected, imageRequests.count < 32 else { completion.complete(encodedImage: nil); return }
        let info = previewPolicy.originalThumbnailInfo(file: file)
        let token = UUID()
        imageRequests[token] = Task { [weak self] in
            guard let self else { completion.complete(encodedImage: nil); return }
            defer { self.imageRequests.removeValue(forKey: token) }
            do {
                guard !self.closed, !Task.isCancelled,
                      let data = try await self.previews.thumbnail(info: info) else {
                    completion.complete(encodedImage: nil); return
                }
                let png = try await self.decoder.queueThumbnailPNG(data)
                guard !self.closed, !Task.isCancelled else { completion.complete(encodedImage: nil); return }
                let bytes = KotlinByteArray(size: Int32(png.count))
                for (index, value) in png.enumerated() { bytes.set(index: Int32(index), value: Int8(bitPattern: value)) }
                completion.complete(encodedImage: bytes)
            } catch { completion.complete(encodedImage: nil) }
        }
    }

    func fixed(value: Double, fractionDigits: Int32) -> String { formatter.fixed(value: value, fractionDigits: fractionDigits) }

    func showConnectionHelp() {
        guard !closed, let presenter, presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil else { return }
        let text = NativeQueueTextCatalog.shared.forLanguage(languageTag: Locale.preferredLanguages.first ?? "en")
        let alert = UIAlertController(title: text.connectionHelpTitle, message: text.connectionHelpMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text.queue.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: text.openAppSettings, style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        presenter.present(alert, animated: true)
    }

    func completedSpeed(value: Float) -> String {
        // Android's completed speed uses the default locale, unlike its POSIX live speed/size.
        String(format: "%.1f MB/s", locale: Locale.current, Double(value))
    }

    func cancelRequests() {
        guard !closed else { return }
        closed = true
        presenter = nil
        requests.values.forEach { $0.cancel() }; requests.removeAll()
        imageRequests.values.forEach { $0.cancel() }; imageRequests.removeAll()
    }

    func close() { model.close() }
}

struct OriginalQueuePage: UIViewControllerRepresentable {
    let bridge: OriginalQueuePageBridge
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> OriginalQueuePageBridge { bridge }
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = SharedUiController.shared.originalQueue(model: bridge.model,
            appearance: AppAppearanceSettings.shared.model, onBack: {
                bridge.close(); dismiss()
                return KotlinUnit()
            })
        bridge.presenter = controller
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: OriginalQueuePageBridge) {
        coordinator.close()
    }
}
