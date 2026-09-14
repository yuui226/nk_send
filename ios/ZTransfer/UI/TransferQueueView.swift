import SwiftUI
import UIKit

/// The queue is a sheet from the same compact pill used on the photo page.  It
/// intentionally contains only the Android queue actions: retry, remove and
/// pause/resume.  Directory selection remains in Settings.
struct TransferQueueView: View {
    @ObservedObject var model: TransferQueueViewModel
    @ObservedObject var directory: DirectoryAccessStore
    let session: CameraSession?
    @Environment(\.dismiss) private var dismiss
    @State private var pendingConfirmation: QueueConfirmation?

    private enum QueueConfirmation: Identifiable {
        case clear, retry
        var id: Self { self }
    }

    init(model: TransferQueueViewModel, session: CameraSession?, directory: DirectoryAccessStore) {
        self.model = model
        self.session = session
        self.directory = directory
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ZTransferColors.background.ignoresSafeArea()
                if model.snapshot.items.isEmpty {
                    DoubleZMark(tint: ZTransferColors.secondaryText.opacity(0.45))
                        .frame(width: 74, height: 58)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            // Android keeps the newest queue task at the top of the list.
                            // Preserve the same ordering when the SwiftUI snapshot is rendered.
                            ForEach(model.snapshot.items.reversed()) { item in
                                QueueItemView(item: item, session: session,
                                              onRetry: { model.retry(id: item.id) },
                                              onRemove: { model.remove(id: item.id) },
                                              onCancel: { model.cancel(id: item.id) })
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 92)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if model.snapshot.items.contains(where: { $0.status == .failed || $0.status == .cancelled }) {
                            Button { pendingConfirmation = .retry } label: { Image(systemName: "arrow.clockwise") }
                                .accessibilityLabel(AppLocalized.resource("cd_retry_failed"))
                        }
                        if model.snapshot.items.contains(where: { $0.status != .transferring && !$0.isGeneratingFrame }) {
                            Button { pendingConfirmation = .clear } label: { Image(systemName: "trash") }
                                .accessibilityLabel(AppLocalized.resource("cd_clear_queue"))
                        }
                        if model.snapshot.isTransferring {
                            Button { model.pause() } label: { Image(systemName: "pause.fill") }
                                .accessibilityLabel(AppLocalized.resource("cd_pause_after_current"))
                        } else if model.snapshot.items.contains(where: { $0.status == .waiting }) {
                            Button {
                                guard let session, let url = directory.directoryURL else { return }
                                model.start(session: session, directory: url)
                            } label: { Image(systemName: "play.fill") }
                                .accessibilityLabel(AppLocalized.resource("cd_start_transfers"))
                        }
                    }
                }
            }
            .task {
                guard let session, let url = directory.directoryURL else { return }
                model.start(session: session, directory: url)
            }
            .alert(item: $pendingConfirmation) { action in
                switch action {
                case .clear:
                    return Alert(title: Text(AppLocalized.resource("clear_queue_title")), message: Text(AppLocalized.resource("clear_queue_subtitle")), primaryButton: .destructive(Text(AppLocalized.resource("clear"))) {
                        model.withdrawPending()
                        Task { try? await Task.sleep(nanoseconds: 320_000_000); model.removeCleared() }
                    }, secondaryButton: .cancel(Text(AppLocalized.resource("cancel"))))
                case .retry:
                    return Alert(title: Text(AppLocalized.resource("retry_failed_title")), primaryButton: .default(Text(AppLocalized.resource("retry"))) { model.retryFailed() }, secondaryButton: .cancel(Text(AppLocalized.resource("cancel"))))
                }
            }
        }
    }
}

private struct QueueItemView: View {
    let item: TransferQueueItem
    let session: CameraSession?
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    private var stateColor: Color {
        switch item.status {
        case .waiting: return ZTransferColors.accentYellow
        case .transferring: return ZTransferColors.accentBlue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return ZTransferColors.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            QueueThumbnail(session: session, handle: item.file.id, item: item)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.file.fileName).zTransferText(size: ZTransferMetrics.caption, weight: .semibold).lineLimit(1)
                HStack(spacing: 6) {
                    if item.isGeneratingFrame {
                        ProgressView().controlSize(.small)
                        Text(AppLocalized.resource("queue_pill_generating")).zTransferText(size: ZTransferMetrics.caption)
                    } else {
                        TransferInfoPill(text: fileSizeText, color: ZTransferColors.secondaryText)
                        if item.status == .transferring, item.bytesPerSecond > 0 {
                            TransferInfoPill(text: speedText, color: ZTransferColors.statusConnected)
                        }
                    }
                    if item.status == .transferring {
                        Text("\(Int(item.progress * 100))%").zTransferText(size: ZTransferMetrics.caption)
                    }
                }
                if let error = item.error, !error.isEmpty {
                    Text(error).zTransferText(size: ZTransferMetrics.caption).foregroundStyle(.red).lineLimit(2)
                }
                if item.status == .transferring {
                    ProgressView(value: item.progress).tint(ZTransferColors.accentBlue)
                }
                if let effectText {
                    TransferInfoPill(text: effectText, color: ZTransferColors.accentPurple)
                }
            }
            Spacer(minLength: 4)
            if item.status == .failed {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).accessibilityLabel(AppLocalized.resource("retry"))
            } else if item.status == .waiting {
                Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(.bordered).accessibilityLabel(AppLocalized.resource("cancel"))
            } else if (item.status == .completed || item.status == .cancelled) && !item.isGeneratingFrame {
                Button(action: onRemove) { Image(systemName: "trash") }.buttonStyle(.bordered).accessibilityLabel(AppLocalized.resource("cd_remove_from_queue"))
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(stateColor.opacity(0.22), lineWidth: 1))
        .animation(ZTransferMotion.standard, value: item.status)
    }

    private var statusText: String {
        switch item.status {
        case .waiting: return AppLocalized.resource("status_waiting")
        case .transferring: return ""
        case .completed: return AppLocalized.resource("done")
        case .failed: return AppLocalized.resource("transfer_failed")
        case .cancelled: return AppLocalized.resource("status_cancelled")
        }
    }

    private var speedText: String {
        let mb = Double(item.bytesPerSecond) / 1_000_000
        return String(format: "%.1f MB/s", mb)
    }

    private var fileSizeText: String {
        let bytes = item.file.size
        if bytes == UInt64(UInt32.max) { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    private var effectText: String? {
        var parts: [String] = []
        if let preset = item.effects?.photoFramePreset, item.effects?.photoFrameEnabled == true,
           let label = frameLabel(preset) { parts.append(label) }
        if let filter = item.effects?.selectedFilter, item.effects?.photoFilterEnabled == true {
            parts.append("\(filter.preset.name) \(filter.normalizedIntensityPercent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func frameLabel(_ preset: PhotoFramePreset) -> String? {
        switch preset {
        case .mist: return AppLocalized.resource("photo_frame_mist")
        case .cinema: return AppLocalized.resource("photo_frame_cinema")
        case .minimal: return AppLocalized.resource("photo_frame_minimal")
        case .frosted: return AppLocalized.resource("photo_frame_frosted")
        case .plaque: return AppLocalized.resource("photo_frame_plaque")
        case .immersive: return AppLocalized.resource("photo_frame_immersive")
        case .brandInset: return AppLocalized.resource("photo_frame_brand_inset")
        case .brandGallery: return AppLocalized.resource("photo_frame_brand_gallery")
        case .classicSignature: return AppLocalized.resource("photo_frame_classic_signature")
        case .galleryMat: return AppLocalized.resource("photo_frame_gallery_mat")
        case .colorArchive: return AppLocalized.resource("photo_frame_color_archive")
        case .filmGallery: return AppLocalized.resource("photo_frame_film_gallery")
        case .filmEdge: return AppLocalized.resource("photo_frame_film_edge")
        }
    }
}

private struct TransferInfoPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .zTransferText(size: ZTransferMetrics.caption, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 1))
            .lineLimit(1)
    }
}

private struct QueueThumbnail: View {
    let session: CameraSession?
    let handle: UInt32
    let item: TransferQueueItem
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)).overlay { Image(systemName: "photo") } }
            }
            Circle()
                .fill(stateColor)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: statusIcon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().stroke(ZTransferColors.background, lineWidth: 2))
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            guard image == nil, let session else { return }
            if let data = try? await session.thumbnail(handle: handle), let image = UIImage(data: data) { self.image = image }
        }
    }

    private var stateColor: Color {
        if item.isGeneratingFrame { return ZTransferColors.accentPurple }
        switch item.status {
        case .waiting: return ZTransferColors.accentYellow
        case .transferring: return ZTransferColors.accentBlue
        case .completed: return ZTransferColors.statusConnected
        case .failed: return ZTransferColors.statusError
        case .cancelled: return ZTransferColors.secondaryText
        }
    }

    private var statusIcon: String {
        if item.isGeneratingFrame { return "sparkles" }
        switch item.status {
        case .waiting: return "clock"
        case .transferring: return "arrow.down"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        }
    }
}
