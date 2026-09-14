import SwiftUI
import UIKit

/// The queue is the second page of the photo-list transfer workspace. It keeps
/// the Android queue actions: retry, remove and pause/resume. Directory
/// selection remains in Settings.
struct TransferQueueView: View {
    @ObservedObject var model: TransferQueueViewModel
    @ObservedObject var directory: DirectoryAccessStore
    let session: CameraSession?
    let onNavigateBack: () -> Void
    @State private var pendingConfirmation: QueueConfirmation?

    fileprivate enum QueueConfirmation: Identifiable {
        case clear, retry
        var id: Self { self }
    }

    init(model: TransferQueueViewModel, session: CameraSession?, directory: DirectoryAccessStore,
         onNavigateBack: @escaping () -> Void) {
        self.model = model
        self.session = session
        self.directory = directory
        self.onNavigateBack = onNavigateBack
    }

    var body: some View {
        ZStack {
            ZTransferColors.background.ignoresSafeArea()
            if model.snapshot.items.isEmpty {
                DoubleZMark(tint: ZTransferColors.secondaryText.opacity(0.45))
                    .frame(width: 74, height: 58)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.snapshot.items.reversed()) { item in
                            QueueItemView(item: item, session: session,
                                          onRetry: { model.retry(id: item.id) },
                                          onRemove: { model.remove(id: item.id) },
                                          onCancel: {
                                              model.cancel(id: item.id)
                                              Task { @MainActor in
                                                  try? await Task.sleep(nanoseconds: 280_000_000)
                                                  model.remove(id: item.id)
                                              }
                                          })
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                    removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                                ))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 62)
                    .padding(.bottom, 112)
                }
                .animation(ZTransferMotion.standard, value: model.snapshot.items)
            }
            queueTopControls
            queueBottomControls
        }
        .overlay { queueConfirmationOverlay }
    }

    private var queueTopControls: some View {
        HStack(spacing: 8) {
            Button(action: onNavigateBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
            Spacer()
            if model.snapshot.isTransferring {
                Button { model.pause() } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                .accessibilityLabel(AppLocalized.resource("cd_pause_after_current"))
            } else if model.snapshot.items.contains(where: { $0.status == .waiting }),
                      let session, let directoryURL = directory.directoryURL {
                Button { model.start(session: session, directory: directoryURL) } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                .accessibilityLabel(AppLocalized.resource("cd_start_transfers"))
            }
            if !model.snapshot.items.isEmpty {
                QueuePill(snapshot: model.snapshot, heldCount: 0)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
            }
            if let session {
                Image(systemName: session.isUSB ? "cable.connector" : "wifi")
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.45), lineWidth: 1))
                    .foregroundStyle(ZTransferColors.statusConnected)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var queueBottomControls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if model.snapshot.items.contains(where: { $0.status == .failed || $0.status == .cancelled }) {
                Button { withAnimation(ZTransferMotion.standard) { pendingConfirmation = .retry } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 48, height: 48)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 24))
                .disabled(session == nil && retryNeedsCamera)
                .opacity(session == nil && retryNeedsCamera ? 0.45 : 1)
                .accessibilityLabel(AppLocalized.resource("cd_retry_failed"))
            }
            if model.snapshot.items.contains(where: { $0.status != .transferring && !$0.isGeneratingFrame }) {
                Button { withAnimation(ZTransferMotion.standard) { pendingConfirmation = .clear } } label: {
                    Image(systemName: "trash").frame(width: 48, height: 48)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 24))
                .accessibilityLabel(AppLocalized.resource("cd_clear_queue"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    private var retryNeedsCamera: Bool {
        model.snapshot.items.contains {
            ($0.status == .failed || $0.status == .cancelled) && $0.outputURL == nil
        }
    }

    @ViewBuilder
    private var queueConfirmationOverlay: some View {
        if let pendingConfirmation {
                ZStack {
                    Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { self.pendingConfirmation = nil }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        QueueConfirmationCard(action: pendingConfirmation,
                                              onConfirm: {
                            switch pendingConfirmation {
                            case .clear:
                                model.withdrawPending()
                                Task {
                                    try? await Task.sleep(nanoseconds: 320_000_000)
                                    model.removeCleared()
                                }
                            case .retry:
                                model.retryFailed()
                            }
                            self.pendingConfirmation = nil
                        }, onDismiss: { self.pendingConfirmation = nil })
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 92)
                }
            }
            .transition(.opacity)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: pendingConfirmation)
        }
    }
}

private struct QueueConfirmationCard: View {
    let action: TransferQueueView.QueueConfirmation
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    private var title: String {
        switch action {
        case .clear: return AppLocalized.resource("clear_queue_title")
        case .retry: return AppLocalized.resource("retry_failed_title")
        }
    }
    private var subtitle: String? {
        switch action {
        case .clear: return AppLocalized.resource("clear_queue_subtitle")
        case .retry: return nil
        }
    }
    private var confirmLabel: String {
        switch action {
        case .clear: return AppLocalized.resource("clear")
        case .retry: return AppLocalized.resource("retry")
        }
    }
    private var tint: Color {
        switch action {
        case .clear: return ZTransferColors.statusError
        case .retry: return ZTransferColors.accentBlue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).zTransferText(size: ZTransferMetrics.body, weight: .bold)
            if let subtitle {
                Text(subtitle).zTransferText(size: ZTransferMetrics.caption)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(AppLocalized.resource("cancel"), action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(ZTransferColors.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .transition(.scale(scale: 0.86, anchor: .bottomTrailing).combined(with: .opacity))
    }
}

private struct QueueItemView: View {
    let item: TransferQueueItem
    let session: CameraSession?
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    private var stateColor: Color {
        if item.isGeneratingFrame { return ZTransferColors.accentPurple }
        switch item.status {
        case .waiting: return ZTransferColors.accentYellow
        case .transferring: return ZTransferColors.accentBlue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return ZTransferColors.secondaryText
        }
    }

    var body: some View {
        ZStack {
            if item.status == .transferring {
                LiquidTransferProgressFill(progress: item.progress, seed: item.id.uuidString)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    QueueThumbnail(session: session, handle: item.file.id, item: item)
                    QueueTaskStatusBadge(item: item)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                Text(item.file.fileName).zTransferText(size: ZTransferMetrics.caption, weight: .semibold).lineLimit(1)
                HStack(spacing: 6) {
                    TransferInfoPill(text: fileSizeText, color: ZTransferColors.secondaryText)
                    if item.status == .transferring, item.bytesPerSecond > 0 {
                        TransferInfoPill(text: speedText, color: ZTransferColors.statusConnected)
                            .transition(.opacity.combined(with: .move(edge: .leading)).combined(with: .scale(scale: 0.86, anchor: .leading)).animation(.easeOut(duration: 0.20).delay(0.06)))
                    }
                    if let elapsed = item.elapsedMs {
                        TransferInfoPill(text: formatDuration(elapsed), color: ZTransferColors.accentBlue)
                            .transition(.opacity.combined(with: .move(edge: .leading)).combined(with: .scale(scale: 0.86, anchor: .leading)).animation(.easeOut(duration: 0.20).delay(0.15)))
                    }
                }
                if let error = item.error, !error.isEmpty {
                    Text(error).zTransferText(size: ZTransferMetrics.caption).foregroundStyle(.red).lineLimit(2)
                }
                Group {
                    if let effectText {
                        HStack(spacing: 6) {
                            TransferInfoPill(text: effectText, color: ZTransferColors.accentPurple)
                            TimelineView(.periodic(from: Date(), by: 0.2)) { timeline in
                                if let elapsed = generationElapsedMs(at: timeline.date) {
                                    TransferInfoPill(text: formatDuration(elapsed), color: ZTransferColors.accentYellow)
                                }
                            }
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .leading)).combined(with: .scale(scale: 0.82, anchor: .leading)).animation(.easeOut(duration: 0.20).delay(0.08)),
                    removal: .opacity.combined(with: .scale(scale: 0.82, anchor: .leading)).animation(.easeIn(duration: 0.14))
                ))
            }
                Spacer(minLength: 4)
                if item.status == .failed {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(session == nil && retryNeedsCamera)
                        .opacity(session == nil && retryNeedsCamera ? 0.45 : 1)
                        .accessibilityLabel(AppLocalized.resource("retry"))
                } else if item.status == .waiting {
                    Button(action: onCancel) { Image(systemName: "trash") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(AppLocalized.resource("cd_remove_from_queue"))
                } else if (item.status == .completed || item.status == .cancelled) && !item.isGeneratingFrame {
                    Button(action: onRemove) { Image(systemName: "trash") }.buttonStyle(.bordered).accessibilityLabel(AppLocalized.resource("cd_remove_from_queue"))
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(stateColor.opacity(0.22), lineWidth: 1))
        .animation(ZTransferMotion.standard, value: item.status)
        .animation(ZTransferMotion.standard, value: item.bytesPerSecond)
        .animation(ZTransferMotion.standard, value: item.elapsedMs)
    }

    private var retryNeedsCamera: Bool {
        item.outputURL == nil
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
        switch item.bytesPerSecond {
        case ..<1024: return "\(item.bytesPerSecond) B/s"
        case ..<(1024 * 1024): return String(format: "%.1f KB/s", Double(item.bytesPerSecond) / 1024)
        default: return String(format: "%.1f MB/s", Double(item.bytesPerSecond) / (1024 * 1024))
        }
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        guard milliseconds >= 0 else { return "0.0s" }
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%dm%02ds", milliseconds / 60000, (milliseconds % 60000) / 1000)
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

    private func generationElapsedMs(at date: Date) -> Int64? {
        if let elapsed = item.frameGenerationElapsedMs { return elapsed }
        guard item.isGeneratingFrame, let started = item.frameGenerationStartedAt else { return nil }
        return Int64(max(0, date.timeIntervalSince(started) * 1000).rounded())
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

/// Android's queue card keeps the task state visible even when the thumbnail
/// itself is still loading. The badge is deliberately independent of the
/// progress fill so state changes can animate without relayout.
private struct QueueTaskStatusBadge: View {
    let item: TransferQueueItem

    private var color: Color {
        if item.isGeneratingFrame { return ZTransferColors.accentPurple }
        switch item.status {
        case .waiting: return ZTransferColors.accentYellow
        case .transferring: return ZTransferColors.accentBlue
        case .completed: return ZTransferColors.statusConnected
        case .failed: return ZTransferColors.statusError
        case .cancelled: return ZTransferColors.secondaryText
        }
    }

    private var icon: String {
        if item.isGeneratingFrame { return "wand.and.stars" }
        switch item.status {
        case .waiting: return "clock"
        case .transferring: return "arrow.down"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        }
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
            .overlay(Circle().stroke(ZTransferColors.background, lineWidth: 2))
            .transition(.opacity.combined(with: .scale(scale: 0.62)))
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: item.status)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: item.isGeneratingFrame)
    }
}

/// Android's transfer cards use a low-amplitude liquid fill instead of a
/// static progress bar. The phase is driven by TimelineView so progress
/// updates do not create a second task per card.
struct LiquidTransferProgressFill: View {
    let progress: Double
    let seed: String

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { timeline in
                LiquidTransferShape(
                    progress: min(max(progress, 0), 1),
                    phase: CGFloat(timeline.date.timeIntervalSinceReferenceDate
                                   .truncatingRemainder(dividingBy: 2.4) / 2.4) + seedPhase
                )
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [ZTransferColors.accentBlue.opacity(0.16), ZTransferColors.accentBlue.opacity(0.30)]),
                        startPoint: .top, endPoint: .bottom
                    ))
            }
        }
        .allowsHitTesting(false)
    }

    private var seedPhase: CGFloat { CGFloat(abs(seed.hashValue % 360)) / 360 }
}

struct LiquidTransferShape: Shape {
    var progress: Double
    var phase: CGFloat

    func path(in rect: CGRect) -> Path {
        let baseline = rect.height * (1 - CGFloat(min(max(progress, 0), 1)))
        let segments = max(8, Int(rect.width / 12))
        let amplitude = min(2.2, rect.height * 0.035)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: baseline))
        for index in 0...segments {
            let fraction = CGFloat(index) / CGFloat(segments)
            let x = rect.width * fraction
            let wave = sin(fraction * .pi * 2 + phase * .pi * 2) * amplitude
            path.addLine(to: CGPoint(x: x, y: baseline + wave))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
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
    @State private var badgeScale: CGFloat = 1
    private var visualState: String {
        if item.isGeneratingFrame { return "generating" }
        return item.status.rawValue
    }

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
                        .id(visualState)
                        .transition(.opacity.combined(with: .scale(scale: 0.62)))
                }
                .overlay(Circle().stroke(ZTransferColors.background, lineWidth: 2))
                .animation(.easeInOut(duration: 0.18), value: visualState)
                .transition(.scale(scale: 0.62).combined(with: .opacity))
                .scaleEffect(badgeScale)
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            guard image == nil, let session else { return }
            // Queue cards follow Android's cache-first policy so opening the
            // queue never adds a fresh camera request for a thumbnail that
            // the photo grid already resolved.
            if let data = try? await session.cachedThumbnail(file: item.file),
               let image = UIImage(data: data) {
                self.image = image
            } else if let data = try? await session.thumbnail(handle: handle),
                      let image = UIImage(data: data) {
                self.image = image
            }
        }
        .onChange(of: visualState) { _ in
            withAnimation(.easeOut(duration: 0.10)) { badgeScale = 0.94 }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.62).delay(0.10)) { badgeScale = 1 }
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
