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
                    DoubleZMark()
                        .fill(ZTransferColors.secondaryText.opacity(0.45))
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
                                .accessibilityLabel("重试失败任务")
                        }
                        if model.snapshot.items.contains(where: { $0.status != .transferring }) {
                            Button { pendingConfirmation = .clear } label: { Image(systemName: "trash") }
                                .accessibilityLabel("清空队列")
                        }
                        if model.snapshot.isTransferring {
                            Button { model.pause() } label: { Image(systemName: "pause.fill") }
                                .accessibilityLabel("传完当前任务后暂停")
                        } else if model.snapshot.items.contains(where: { $0.status == .waiting }) {
                            Button {
                                guard let session, let url = directory.directoryURL else { return }
                                model.start(session: session, directory: url)
                            } label: { Image(systemName: "play.fill") }
                                .accessibilityLabel("开始传输")
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
                    return Alert(title: Text("清空队列？"), message: Text("移除全部卡片；正在传输的不受影响"), primaryButton: .destructive(Text("清空")) {
                        model.withdrawPending()
                        Task { try? await Task.sleep(nanoseconds: 320_000_000); model.removeCleared() }
                    }, secondaryButton: .cancel(Text("取消")))
                case .retry:
                    return Alert(title: Text("重试失败任务？"), primaryButton: .default(Text("重试")) { model.retryFailed() }, secondaryButton: .cancel(Text("取消")))
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
            QueueThumbnail(session: session, handle: item.file.id)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.file.fileName).zTransferText(size: ZTransferMetrics.caption, weight: .semibold).lineLimit(1)
                HStack(spacing: 6) {
                    if item.status != .transferring {
                        Circle().fill(stateColor).frame(width: 7, height: 7)
                        Text(statusText).zTransferText(size: ZTransferMetrics.caption)
                    }
                    if item.status == .transferring {
                        Text("\(Int(item.progress * 100))%").zTransferText(size: ZTransferMetrics.caption)
                        if item.bytesPerSecond > 0 { Text(speedText).zTransferText(size: ZTransferMetrics.caption) }
                    }
                }
                if let error = item.error, !error.isEmpty {
                    Text(error).zTransferText(size: ZTransferMetrics.caption).foregroundStyle(.red).lineLimit(2)
                }
                if item.status == .transferring {
                    ProgressView(value: item.progress).tint(ZTransferColors.accentBlue)
                }
            }
            Spacer(minLength: 4)
            if item.status == .failed {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).accessibilityLabel("重试")
            } else if item.status == .waiting {
                Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(.bordered).accessibilityLabel("取消")
            } else if item.status == .completed || item.status == .cancelled {
                Button(action: onRemove) { Image(systemName: "trash") }.buttonStyle(.bordered).accessibilityLabel("移出队列")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(stateColor.opacity(0.22), lineWidth: 1))
        .animation(ZTransferMotion.standard, value: item.status)
    }

    private var statusText: String {
        switch item.status {
        case .waiting: return "等待"
        case .transferring: return ""
        case .completed: return "完成"
        case .failed: return "传输失败"
        case .cancelled: return "已取消"
        }
    }

    private var speedText: String {
        let mb = Double(item.bytesPerSecond) / 1_000_000
        return String(format: "%.1f MB/s", mb)
    }
}

private struct QueueThumbnail: View {
    let session: CameraSession?
    let handle: UInt32
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)).overlay { Image(systemName: "photo") } }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            guard image == nil, let session else { return }
            if let data = try? await session.thumbnail(handle: handle), let image = UIImage(data: data) { self.image = image }
        }
    }
}
