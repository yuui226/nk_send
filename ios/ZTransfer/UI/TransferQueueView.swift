import SwiftUI
import UIKit

/// The queue is the second page of the photo-list transfer workspace. It keeps
/// the Android queue actions: retry, remove and pause/resume. Directory
/// selection remains in Settings.
struct TransferQueueView: View {
    @ObservedObject var model: TransferQueueViewModel
    @ObservedObject var directory: DirectoryAccessStore
    let session: CameraSession?
    let isSessionConnected: Bool
    let onRetrySTA: () -> Void
    let onNavigateBack: () -> Void
    @State private var pendingConfirmation: QueueConfirmation?
    @State private var removingItemIDs: Set<UUID> = []
    @State private var clearAllInProgress = false

    fileprivate enum QueueConfirmation: Identifiable {
        case clear, retry
        var id: Self { self }
    }

    init(model: TransferQueueViewModel, session: CameraSession?, directory: DirectoryAccessStore,
         isSessionConnected: Bool = true, onRetrySTA: @escaping () -> Void = {},
         onNavigateBack: @escaping () -> Void) {
        self.model = model
        self.session = session
        self.isSessionConnected = isSessionConnected
        self.onRetrySTA = onRetrySTA
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
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(model.snapshot.items.reversed()) { item in
                            QueueItemView(item: item, session: session,
                                          activeProgress: model.activeProgress,
                                          isRemoving: removingItemIDs.contains(item.id),
                                          onRetry: { model.retry(id: item.id) },
                                          onRemove: { beginRemoval(item.id, withdraw: false) },
                                          onWithdraw: { beginRemoval(item.id, withdraw: true) })
                                // Android first collapses the row's reported height;
                                // data removal happens after the 280 ms exit.
                                .transition(.identity)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 58)
                    .padding(.bottom, 112)
                }
                .animation(ZTransferMotion.standard, value: model.snapshot.items)
            }
            queueTopControls
            queueBottomControls
        }
        .overlay { queueConfirmationOverlay }
        .onChange(of: model.snapshot.items.map(\.id)) { ids in
            // Keep the collapse state until the actor publishes the actual
            // removal; clearing it in the same task as `remove` would briefly
            // expand the old row before the snapshot arrives.
            removingItemIDs = removingItemIDs.filter { ids.contains($0) }
        }
    }

    private func beginRemoval(_ id: UUID, withdraw: Bool) {
        guard !removingItemIDs.contains(id) else { return }
        removingItemIDs.insert(id)
        if withdraw { model.withdraw(id: id) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            if !(await model.remove(id: id)) { removingItemIDs.remove(id) }
        }
    }

    private var queueTopControls: some View {
        HStack(spacing: 8) {
            Button(action: onNavigateBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
            if let session {
                Button {
                    if session.wirelessMode == .sta && !isSessionConnected { onRetrySTA() }
                } label: {
                    PhotoListSignalIcon(isUSB: session.isUSB, wirelessMode: session.wirelessMode,
                                        connected: isSessionConnected)
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()

        }
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var queueBottomControls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if !clearAllInProgress && !model.snapshot.isTransferring && actionItems.contains(where: { $0.status == .failed || $0.status == .cancelled }) {
                Button { withAnimation(ZTransferMotion.standard) { pendingConfirmation = .retry } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 48, height: 48)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 24))
                .disabled(session == nil && retryNeedsCamera)
                .opacity(session == nil && retryNeedsCamera ? 0.45 : 1)
                .accessibilityLabel(AppLocalized.resource("cd_retry_failed"))
            }
            if !clearAllInProgress && actionItems.contains(where: { $0.status != .transferring && !$0.isGeneratingFrame }) {
                Button { withAnimation(ZTransferMotion.standard) { pendingConfirmation = .clear } } label: {
                    QueueBroomMark(color: ZTransferColors.primaryText)
                        .frame(width: 22, height: 22)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 24))
                .accessibilityLabel(AppLocalized.resource("cd_clear_queue"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    private var actionItems: [TransferQueueItem] {
        model.snapshot.items.filter { !removingItemIDs.contains($0.id) }
    }

    private var retryNeedsCamera: Bool {
        actionItems.contains {
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
                                clearAllInProgress = true
                                model.withdrawPending()
                                for item in model.snapshot.items where item.status != .transferring && !item.isGeneratingFrame {
                                    beginRemoval(item.id, withdraw: false)
                                }
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 320_000_000)
                                    await model.removeCleared()
                                    clearAllInProgress = false
                                }
                            case .retry:
                                model.retryFailed(excluding: removingItemIDs)
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
    let activeProgress: TransferActiveProgress?
    let isRemoving: Bool
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onWithdraw: () -> Void
    @State private var measuredHeight: CGFloat = 0
    @State private var collapseProgress: CGFloat = 1

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
                LiquidTransferProgressFill(progress: displayedProgress, seed: item.id.uuidString)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    QueueThumbnail(session: session, handle: item.file.id, item: item)
                    QueueTaskStatusBadge(item: item)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                Text(item.file.fileName).zTransferText(size: ZTransferMetrics.caption, weight: .semibold).lineLimit(1)
                HStack(spacing: 6) {
                    TransferInfoPill(text: fileSizeText, color: ZTransferColors.secondaryText)
                    if let speedText {
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
                if item.status == .failed && !isRemoving {
                    QueueActionButton(icon: "arrow.clockwise", action: onRetry)
                        .disabled(session == nil && retryNeedsCamera)
                        .opacity(session == nil && retryNeedsCamera ? 0.45 : 1)
                        .accessibilityLabel(AppLocalized.resource("retry"))
                        .transition(.opacity.combined(with: .scale(scale: 0.75, anchor: .topTrailing)))
                }
                if item.status == .waiting && !isRemoving {
                    QueueActionButton(icon: "broom", action: onWithdraw)
                        .accessibilityLabel(AppLocalized.resource("cd_remove_from_queue"))
                        .transition(.opacity.combined(with: .scale(scale: 0.75, anchor: .trailing)))
                } else if (item.status == .completed || item.status == .cancelled || item.status == .failed) && !item.isGeneratingFrame && !isRemoving {
                    QueueActionButton(icon: "broom", action: onRemove)
                        .accessibilityLabel(AppLocalized.resource("cd_remove_from_queue"))
                        .transition(.opacity.combined(with: .scale(scale: 0.75, anchor: .trailing)))
                }
            }
            .padding(12)
        }
        .background {
            Color(uiColor: .secondarySystemGroupedBackground)
                .overlay(stateColor.opacity(0.055))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.35), lineWidth: 1))
        .animation(ZTransferMotion.standard, value: item.status)
        .animation(ZTransferMotion.standard, value: item.bytesPerSecond)
        .animation(ZTransferMotion.standard, value: item.elapsedMs)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: QueueItemHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(QueueItemHeightPreferenceKey.self) { measuredHeight = $0 }
        .frame(height: measuredHeight > 0 ? measuredHeight * collapseProgress : nil, alignment: .top)
        .clipped()
        .opacity(collapseProgress)
        .onChange(of: isRemoving) { removing in
            withAnimation(.easeInOut(duration: 0.28)) {
                collapseProgress = removing ? 0 : 1
            }
        }
    }

    private var retryNeedsCamera: Bool {
        item.outputURL == nil
    }

    private var speedText: String? {
        if item.status == .completed, item.downloadMBps > 0 {
            return String(format: "%.1f MB/s", item.downloadMBps)
        }
        guard item.status == .transferring, displayedBytesPerSecond > 0 else { return nil }
        switch displayedBytesPerSecond {
        case ..<1024: return "\(displayedBytesPerSecond) B/s"
        case ..<(1024 * 1024): return String(format: "%.1f KB/s", Double(displayedBytesPerSecond) / 1024)
        default: return String(format: "%.1f MB/s", Double(displayedBytesPerSecond) / (1024 * 1024))
        }
    }

    private var displayedProgress: Double {
        activeProgress?.taskID == item.id ? activeProgress!.fraction : item.progress
    }

    private var displayedBytesPerSecond: Int64 {
        activeProgress?.taskID == item.id ? activeProgress!.bytesPerSecond : item.bytesPerSecond
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

private struct QueueItemHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct QueueActionButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if icon == "broom" {
                    QueueBroomMark(color: ZTransferColors.primaryText)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16))
    }
}

/// The queue uses the same single-color broom mark for both “remove” actions
/// and the clear FAB. Keeping it as a path avoids substituting a platform trash
/// glyph whose silhouette and baseline differ from Android.
private struct QueueBroomMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            var mark = Path()
            mark.move(to: CGPoint(x: s * 0.57, y: s * 0.10))
            mark.addLine(to: CGPoint(x: s * 0.42, y: s * 0.46))
            mark.move(to: CGPoint(x: s * 0.31, y: s * 0.48))
            mark.addLine(to: CGPoint(x: s * 0.67, y: s * 0.63))
            for index in 0..<5 {
                let x = s * (0.35 + CGFloat(index) * 0.075)
                mark.move(to: CGPoint(x: x, y: s * 0.61))
                mark.addQuadCurve(
                    to: CGPoint(x: x - s * 0.10, y: s * (0.88 + CGFloat(index) * 0.012)),
                    control: CGPoint(x: x + s * 0.02, y: s * 0.72)
                )
            }
            context.stroke(mark, with: .color(color), style: StrokeStyle(lineWidth: max(1.4, s * 0.075), lineCap: .round, lineJoin: .round))
        }
        .rotationEffect(.degrees(45))
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
/// All four transfer surfaces use Android's critically damped progress spring.
struct SmoothTransferProgress<Content: View>: View {
    let target: Double
    let resetKey: AnyHashable?
    @ViewBuilder let content: (Double) -> Content
    @State private var accepted = 0.0
    var body: some View {
        content(accepted)
            .onAppear { advance() }
            .onChange(of: target) { _ in advance() }
            .onChange(of: resetKey) { _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { accepted = 0 }
                advance()
            }
    }
    private func advance() {
        let normalized = target.isFinite ? min(max(target, 0), 1) : 0
        guard normalized > accepted else { return }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 180, damping: 2 * sqrt(180))) {
            accepted = normalized
        }
    }
}

struct LiquidTransferProgressFill: View {
    let progress: Double
    let seed: String
    var isCapsule = false
    var body: some View {
        SmoothTransferProgress(target: progress, resetKey: seed) { value in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: value <= 0 || value >= 1)) { timeline in
                LiquidTransferShape(progress: value,
                    phase: CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: isCapsule ? 2.2 : 2.6) / (isCapsule ? 2.2 : 2.6)),
                    seed: seedPhase, amplitude: isCapsule ? 2 : 3,
                    segments: isCapsule ? 8 : 12, spatialScale: isCapsule ? 1 : 0.55)
                    .fill(ZTransferColors.accentBlue.opacity(isCapsule ? 0.22 : 0.14))
            }
        }.allowsHitTesting(false)
    }
    private var seedPhase: CGFloat {
        let hash = seed.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        return CGFloat(hash & 0xffff) / 65535
    }
}

struct LiquidTransferShape: Shape {
    var progress: Double
    var phase: CGFloat
    var seed: CGFloat = 0
    var amplitude: CGFloat = 3
    var segments: Int = 12
    var spatialScale: CGFloat = 0.55
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let p = CGFloat(progress.isFinite ? min(max(progress, 0), 1) : 0)
        guard p > 0 else { return Path() }
        func smooth(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            let t = min(max((p - start) / (end - start), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let envelope = smooth(0.05, 0.14) * (1 - smooth(0.90, 0.98))
        let time = phase * 2 * .pi
        let seedAngle = seed * 2 * .pi
        let waveAmplitude = amplitude * envelope * (0.90 + 0.10 * sin(2 * time + seedAngle))
        func edge(_ y: CGFloat) -> CGFloat {
            let y = y * spatialScale * 2 * .pi
            let wave = 0.64 * sin(time + y * 1.15 + seedAngle)
                + 0.24 * sin(-2 * time + y * 2.40 + seedAngle * 0.73)
                + 0.12 * sin(3 * time + y * 3.35 + seedAngle * 1.31)
            return min(max(rect.width * p + waveAmplitude * wave, 0), rect.width)
        }
        var path = Path()
        path.move(to: .zero)
        var previous = CGPoint(x: edge(0), y: 0)
        path.addLine(to: previous)
        for i in 1...max(2, segments) {
            let fraction = CGFloat(i) / CGFloat(max(2, segments))
            let next = CGPoint(x: edge(fraction), y: rect.height * fraction)
            path.addQuadCurve(to: CGPoint(x: (previous.x + next.x) / 2, y: (previous.y + next.y) / 2), control: previous)
            previous = next
        }
        path.addQuadCurve(to: previous, control: previous)
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct TransferInfoPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .zTransferText(size: 10, weight: .medium)
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
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)).overlay { Image(systemName: "photo") } }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            guard image == nil, let session else { return }
            if let data = try? await session.cachedThumbnail(file: item.file), let image = UIImage(data: data) {
                self.image = image
            } else if let data = try? await session.thumbnail(handle: handle), let image = UIImage(data: data) {
                self.image = image
            }
        }
    }
}
