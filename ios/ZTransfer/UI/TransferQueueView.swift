import SwiftUI
import UIKit

func transferCardProgressTarget(status: TransferStatus, progress: Double) -> Double {
    status == .completed ? 1 : (progress.isFinite ? min(max(progress, 0), 1) : 0)
}

func transferCardWaveEligible(status: TransferStatus) -> Bool {
    status == .transferring || status == .completed
}

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
    let showsTopControls: Bool
    let controlActionNonce: UInt64
    let hasIndexedOriginal: (TransferQueueItem) -> Bool
    @State private var mountedConfirmations: Set<QueueConfirmation> = []
    // Keep frame-frequency scrim changes out of the queue/card body.
    @State private var confirmationProgress = QueueConfirmationProgress()
    @State private var pendingConfirmation: QueueConfirmation?
    @StateObject private var removal = QueueRemovalCoordinator()
    @State private var listAtTop = true
    @Environment(\.displayScale) private var displayScale

    fileprivate enum QueueConfirmation: Identifiable, Hashable {
        case clear, retry
        var id: Self { self }
    }

    init(model: TransferQueueViewModel, session: CameraSession?, directory: DirectoryAccessStore,
         isSessionConnected: Bool = true,
         onRetrySTA: @escaping () -> Void = {},
         showsTopControls: Bool = true,
         controlActionNonce: UInt64 = 0,
         hasIndexedOriginal: @escaping (TransferQueueItem) -> Bool = { _ in false },
         onNavigateBack: @escaping () -> Void) {
        self.model = model
        self.session = session
        self.isSessionConnected = isSessionConnected
        self.onRetrySTA = onRetrySTA
        self.hasIndexedOriginal = hasIndexedOriginal
        self.controlActionNonce = controlActionNonce
        self.showsTopControls = showsTopControls
        self.directory = directory
        self.onNavigateBack = onNavigateBack
    }

    var body: some View {
        ZStack {
            ZTransferColors.background.ignoresSafeArea()
            if model.snapshot.items.isEmpty {
                QueueEmptyMark()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.snapshot.items.reversed()) { item in
                            QueueProgressScope(model: model.progressModel, active: item.status == .transferring) { progress in
                                QueueItemView(item: item, session: session,
                                              thumbnailRetryNudge: model.snapshot.isTransferring,
                                              activeProgress: progress,
                                              isRemoving: removal.removingIDs.contains(item.id),
                                              isClearing: removal.isClearing,
                                              retryEnabled: isSessionConnected || !item.retryNeedsCamera(hasIndexedOriginal: hasIndexedOriginal(item)),
                                              onRetry: { model.retry(id: item.id) },
                                              onWithdraw: { removal.withdraw(item.id, model: model) },
                                              onRemovalAbandoned: { removal.abandon(item.id) })
                                    // Android first collapses the row's reported height;
                                    // data removal happens after the 280 ms exit.
                                    .modifier(QueueItemPlacement())
                                    .transition(.identity)
                            }
                        }
                    }
                    .coordinateSpace(name: QueueItemPlacement.coordinateSpace)
                    .padding(.horizontal, 12)
                    .padding(.top, 58)
                    .padding(.bottom, listBottomPadding)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: QueueScrollOffsetKey.self,
                                value: -proxy.frame(in: .named("transfer-queue-scroll")).minY)
                        }
                    }
                }
                .coordinateSpace(name: "transfer-queue-scroll")
                .onPreferenceChange(QueueScrollOffsetKey.self) { offset in
                    listAtTop = PhotoListScrollActivity.isAtTop(offset: offset, scale: displayScale)
                }
            }
            queueTopScrim
            if showsTopControls { queueTopControls }
            queueConfirmationScrim
            queueBottomControls
        }
        .onChange(of: model.snapshot.items.map(\.id)) { ids in
            if ids.isEmpty { listAtTop = true }
            removal.synchronize(liveIDs: Set(ids))
        }
        .onChange(of: actionVisibility) { visibility in
            if pendingConfirmation == .retry && !visibility.hasRetryable ||
                pendingConfirmation == .clear && !visibility.hasClearable {
                pendingConfirmation = nil
            }
        }
        .onChange(of: controlActionNonce) { nonce in
            if nonce > 0 { pendingConfirmation = nil }
        }
        .onDisappear { removal.leave() }
        #if DEBUG
        .onChange(of: removal.isClearing) { QueueClearInteractionTrace.shared.clearingChanged($0) }
        .onChange(of: model.snapshot.items) { QueueClearInteractionTrace.shared.snapshotChanged($0) }
        #endif
    }

    private var queueTopScrim: some View {
        GeometryReader { proxy in
            if !listAtTop && !model.snapshot.items.isEmpty {
                LinearGradient(stops: [
                    .init(color: ZTransferColors.backgroundTop.opacity(0.85), location: 0),
                    .init(color: ZTransferColors.backgroundTop.opacity(0.5), location: 0.45),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: proxy.safeAreaInsets.top + 56)
                .offset(y: -proxy.safeAreaInsets.top)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { $0.animation = nil }
    }

    private var queueTopControls: some View {
        HStack(spacing: 8) {
            Button(action: onNavigateBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 40, height: 40)
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
            if let session {
                CameraSignalControl(isUSB: session.isUSB, wirelessMode: session.wirelessMode,
                                    connected: isSessionConnected, height: 40)
            }
            Spacer()

        }
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var queueBottomControls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            QueueFabVisibility(visible: actionVisibility.hasRetryable || mountedConfirmations.contains(.retry)) {
                confirmationFab(.retry, enabled: confirmationIsEnabled(.retry)) {
                    RemoteEditorIcon(kind: .refresh)
                        .fill(isSessionConnected ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                        .frame(width: 26, height: 26)
                }
            }
            QueueFabVisibility(visible: actionVisibility.hasClearable || mountedConfirmations.contains(.clear)) {
                confirmationFab(.clear, enabled: confirmationIsEnabled(.clear)) {
                    QueueBroomMark(color: ZTransferColors.primaryText).frame(width: 26, height: 26)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    private func confirmationFab<Label: View>(_ action: QueueConfirmation, enabled: Bool,
                                               @ViewBuilder label: () -> Label) -> some View {
        QueueConfirmationFab(action: action, expanded: pendingConfirmation == action,
            mounted: mountedConfirmations.contains(action), enabled: enabled, label: label(),
            onToggle: { toggleConfirmation(action) }, onConfirm: { confirm(action) }, onDismiss: {
                // Android dismisses this action's flag, not the other panel.
                if pendingConfirmation == action { pendingConfirmation = nil }
            },
            onProgress: { confirmationProgress.values[action] = $0 }, onClosed: {
                guard pendingConfirmation != action else { return }
                mountedConfirmations.remove(action)
                confirmationProgress.values[action] = nil
            })
    }

    private func confirmationIsEnabled(_ action: QueueConfirmation) -> Bool {
        switch action {
        case .clear: return actionVisibility.hasClearable
        case .retry: return actionVisibility.hasRetryable && (isSessionConnected || !retryNeedsCamera)
        }
    }

    private func toggleConfirmation(_ action: QueueConfirmation) {
        guard confirmationIsEnabled(action) else { return }
        #if DEBUG
        QueueConfirmationAnimationTrace.shared.toggle(
            closing: pendingConfirmation == action, reopen: { toggleConfirmation(action) })
        #endif
        if pendingConfirmation == action { pendingConfirmation = nil }
        else { mountedConfirmations.insert(action); pendingConfirmation = action }
    }

    @ViewBuilder
    private var queueConfirmationScrim: some View {
        if !mountedConfirmations.isEmpty {
            QueueConfirmationScrim(progress: confirmationProgress) { pendingConfirmation = nil }
        }
    }

    private var actionVisibility: TransferQueueSnapshot.ActionVisibility {
        model.snapshot.actionVisibility(excluding: removal.removingIDs, suppressAll: removal.isClearing)
    }

    private var listBottomPadding: CGFloat {
        // TransferScreen.listPadding counts eligible actions, not outgoing
        // confirmation hosts. SwiftUI already supplies the bottom safe area.
        let visibility = actionVisibility
        switch (visibility.hasClearable, visibility.hasRetryable) {
        case (true, true): return 168
        case (false, false): return 12
        default: return 96
        }
    }

    private var actionItems: [TransferQueueItem] {
        model.snapshot.items.filter { !removal.removingIDs.contains($0.id) }
    }

    private var retryNeedsCamera: Bool {
        actionItems.contains {
            $0.canRetry && $0.retryNeedsCamera(hasIndexedOriginal: hasIndexedOriginal($0))
        }
    }

    private func confirm(_ action: QueueConfirmation) {
        // Retained closing content may still deliver an old callback. Only
        // the current, still-eligible confirmation may dispatch a command.
        guard pendingConfirmation == action else { return }
        // Android gates the open FAB on connectivity, but an already-open
        // confirmation remains available until its task eligibility disappears.
        let eligible = action == .clear ? actionVisibility.hasClearable : actionVisibility.hasRetryable
        guard eligible else { pendingConfirmation = nil; return }
        pendingConfirmation = nil
        switch action {
        case .clear:
            removal.clear(model: model)
        case .retry:
            model.retryFailed(excluding: removal.removingIDs)
        }
    }
}

/// TransferScreen's per-row 280ms removal and clearScope 320ms fallback
/// share the screen lifetime. Keep operation ownership out of view values so
/// leaving/reentering cannot let an old cleanup mutate a new removal batch.
@MainActor
final class QueueRemovalCoordinator: ObservableObject {
    @Published private(set) var removingIDs: Set<UUID> = []
    @Published private(set) var isClearing = false
    private var removalTasks: [UUID: Task<Void, Never>] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private var lifetime = UUID()

    func withdraw(_ id: UUID, model: TransferQueueViewModel) {
        guard !removingIDs.contains(id) else { return }
        model.withdraw(id: id)
        beginRemoval([id], model: model)
    }

    func clear(model: TransferQueueViewModel) {
        guard !isClearing else { return }
        isClearing = true
        model.withdrawPending()
        beginRemoval(Set(model.snapshot.items.lazy
            .filter { $0.status != .transferring && !$0.isGeneratingFrame }.map(\.id)), model: model)
        let operation = UUID()
        cleanupID = operation
        cleanupTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 320_000_000) }
            catch { return }
            guard let self, cleanupID == operation else { return }
            await model.removeCleared()
            guard cleanupID == operation else { return }
            isClearing = false; cleanupTask = nil; cleanupID = nil
        }
    }

    private func beginRemoval(_ requestedIDs: Set<UUID>, model: TransferQueueViewModel) {
        let ids = requestedIDs.subtracting(removingIDs)
        guard !ids.isEmpty else { return }
        removingIDs.formUnion(ids)
        let operation = UUID(), generation = lifetime
        removalTasks[operation] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 280_000_000) }
            catch { return }
            guard let self, lifetime == generation else { return }
            defer { removalTasks.removeValue(forKey: operation) }
            // A vertically disposed row abandons its individual removal. The
            // separate clear fallback still cleans terminal offscreen rows.
            let retained = ids.intersection(removingIDs)
            guard !retained.isEmpty else { return }
            let removed = await model.remove(ids: retained)
            guard lifetime == generation else { return }
            removingIDs.subtract(retained.subtracting(removed))
        }
    }

    func abandon(_ id: UUID) { removingIDs.remove(id) }

    func synchronize(liveIDs: Set<UUID>) {
        // Keep successful collapses until the actor's snapshot is visible;
        // clearing before publication would briefly expand the old row.
        let retained = removingIDs.intersection(liveIDs)
        if retained != removingIDs { removingIDs = retained }
    }

    func leave() {
        lifetime = UUID()
        for task in removalTasks.values { task.cancel() }
        removalTasks.removeAll()
        cleanupTask?.cancel(); cleanupTask = nil; cleanupID = nil
        removingIDs.removeAll(); isClearing = false
    }

    deinit {
        for task in removalTasks.values { task.cancel() }
        cleanupTask?.cancel()
    }
}

/// TransferScreen uses fadeIn/out + scaleIn/out(0.6), all with Compose's
/// default critically damped spring(400). Each Float has its own threshold;
/// retain the layout until both channels finish, including interruptions.
struct QueueFabVisibilityMotion {
    private(set) var visible: Bool
    private(set) var retained: Bool
    private(set) var alpha: ZTransferScalarAnimation
    private(set) var scale: ZTransferScalarAnimation
    private var lastFrameNanos: Int64?
    var isRunning: Bool { alpha.isRunning || scale.isRunning }

    init(visible: Bool = false) {
        self.visible = visible
        retained = visible
        alpha = .init(value: visible ? 1 : 0)
        scale = .init(value: visible ? 1 : 0.6)
    }
    mutating func setVisible(_ value: Bool) {
        guard value != visible else { return }
        if value && !retained {
            alpha = .init(value: 0)
            scale = .init(value: 0.6)
        }
        let origin = isRunning ? lastFrameNanos : nil
        visible = value
        retained = true
        alpha.retarget(value ? 1 : 0, using: .criticallyDampedSpring(stiffness: 400), atFrameNanos: origin)
        scale.retarget(value ? 1 : 0.6, using: .criticallyDampedSpring(stiffness: 400), atFrameNanos: origin)
    }
    mutating func advance(_ now: Int64) {
        lastFrameNanos = now
        alpha.advance(frameNanos: now)
        scale.advance(frameNanos: now)
        if !visible && !isRunning { retained = false }
    }
}

@MainActor
final class QueueFabVisibilityAnimator: NSObject, ObservableObject {
    @Published private(set) var motion: QueueFabVisibilityMotion
    private var link: CADisplayLink?
    init(visible: Bool) { motion = .init(visible: visible) }
    func setVisible(_ value: Bool) {
        if motion.visible != value { motion.setVisible(value) }
        guard motion.isRunning, link == nil else { return }
        let link = ZTransferDisplayLink.make(owner: self) { $0.frame($1) }
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000))
        if !motion.isRunning { link.invalidate(); self.link = nil }
    }
    func stop() {
        link?.invalidate(); link = nil
        motion = .init(visible: motion.visible)
    }
}

private struct QueueFabVisibility<Content: View>: View {
    let visible: Bool
    let content: Content
    @StateObject private var animator: QueueFabVisibilityAnimator
    init(visible: Bool, @ViewBuilder content: () -> Content) {
        self.visible = visible
        self.content = content()
        _animator = StateObject(wrappedValue: QueueFabVisibilityAnimator(visible: visible))
    }
    var body: some View {
        Group {
            if animator.motion.retained {
                content
                    .scaleEffect(CGFloat(animator.motion.scale.value), anchor: .center)
                    .opacity(Double(animator.motion.alpha.value))
            }
        }
        .onAppear { animator.setVisible(visible) }
        .onChange(of: visible) { animator.setVisible($0) }
        .onDisappear { animator.stop() }
    }
}

/// Only the scrim subscribes to the Genie display clock. The parent retains
/// this reference in State, so progress does not invalidate the entire queue.
@MainActor
private final class QueueConfirmationProgress: ObservableObject {
    @Published var values: [TransferQueueView.QueueConfirmation: CGFloat] = [:]
}

private struct QueueConfirmationScrim: View {
    @ObservedObject var progress: QueueConfirmationProgress
    @Environment(\.colorScheme) private var colorScheme
    let onDismiss: () -> Void

    var body: some View {
        Color.black.opacity((colorScheme == .dark ? 0.4 : 0.32) *
                            Double(progress.values.values.max() ?? 0))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .gesture(DragGesture(minimumDistance: 1).onChanged { _ in })
    }
}

/// Like Android ConfirmFab, the outgoing card retains its layout slot and
/// trigger until the shared Genie clock reaches zero. Each FAB owns geometry.
private struct QueueConfirmationFab<Label: View>: View {
    let action: TransferQueueView.QueueConfirmation
    let expanded: Bool
    let mounted: Bool
    let enabled: Bool
    let label: Label
    let onToggle: () -> Void
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let onProgress: (CGFloat) -> Void
    let onClosed: () -> Void
    @State private var geometry: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if mounted {
                let panel = geometry["panel"] ?? .zero
                let button = geometry["button"] ?? .zero
                let ready = panel.width > 0 && button.width > 0
                // Android ConfirmFab supplies the full trigger bounds; the mesh
                // itself limits the mouth to GENIE_Z_MARK_WIDTH_DP.
                let anchor = button
                GeniePopupPanel(
                    content: QueueConfirmationCard(action: action, onConfirm: onConfirm, onDismiss: onDismiss),
                    trigger: action == .retry ? .queueRetry : .queueClear,
                    targetProgress: ready && expanded ? 1 : 0,
                    anchorX: ready ? (anchor.midX - panel.minX) / panel.width : 0,
                    anchorWidth: ready ? anchor.width / panel.width : 0,
                    anchorGap: ready ? button.minY - panel.maxY : 0,
                    opensAbove: true,
                    fitsContentWidth: true,
                    onSettled: { value in if value == 0 && !expanded { onClosed() } },
                    onProgress: reportProgress
                )
                #if DEBUG
                .onAppear { QueueConfirmationAnimationTrace.shared.panelAppeared() }
                #endif
                .background(bounds("panel"))
                .frame(maxWidth: 260, alignment: .trailing)
            }
            Spacer().frame(height: 12)
            Button(action: onToggle) { label.padding(16) }
                .accessibilityIdentifier(action == .retry ? "queue-retry-all" : "queue-clear-all")
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 29))
                .disabled(!enabled)
                .accessibilityLabel(AppLocalized.resource(action == .retry ? "cd_retry_failed" : "cd_clear_queue"))
                .background(bounds("button"))
        }
        .onPreferenceChange(QueueConfirmationBounds.self) { geometry = $0 }
    }

    private func reportProgress(_ value: CGFloat) {
        onProgress(value)
        #if DEBUG
        QueueConfirmationAnimationTrace.shared.record(value, expanded: expanded)
        #endif
    }

    private func bounds(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: QueueConfirmationBounds.self,
                                   value: [key: proxy.frame(in: .global)])
        }
    }
}

private struct QueueConfirmationBounds: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Android widthIn(max=260) + Column: first resolve the natural width,
/// then remeasure multiline content at that width before publishing height.
private struct QueueConfirmationContentLayout: Layout {
    private func measurements(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGFloat, [CGSize]) {
        let limit = max(1, min(228, proposal.width ?? 228)) // 260 minus the two 16pt insets
        let width = min(limit, subviews.map {
            $0.sizeThatFits(.unspecified).width
        }.max() ?? 0)
        return (width, subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, sizes) = measurements(proposal, subviews)
        return CGSize(width: width, height: sizes.reduce(0) { $0 + $1.height } + (sizes.count == 3 ? 16 : 12))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.init(width: bounds.width, height: nil))
            let isActions = index == subviews.count - 1
            subview.place(at: CGPoint(x: isActions ? bounds.maxX - size.width : bounds.minX, y: y),
                          proposal: .init(width: size.width, height: size.height))
            y += size.height
            if index < subviews.count - 1 { y += index == 0 && subviews.count == 3 ? 4 : 12 }
        }
    }
}

private struct QueueConfirmationCard: View {
    let action: TransferQueueView.QueueConfirmation
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

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
        QueueConfirmationContentLayout {
            Text(title).zTransferTypography(.titleSmall, weight: .bold).tracking(0.1)
            if let subtitle {
                Text(subtitle).zTransferTypography(.bodySmall, weight: .regular)
                    .accessibilityIdentifier("queue-confirmation-subtitle")
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            HStack(spacing: 8) {
                actionButton(AppLocalized.resource("cancel"), primary: false, action: onDismiss)
                actionButton(confirmLabel, primary: true, action: onConfirm)
                    .accessibilityIdentifier("queue-confirm-action")
            }
        }
        .padding(16)
        .background(ZTransferColors.surface.opacity(scheme == .dark ? 0.92 : 0.95),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.4), lineWidth: 1))
        .background { AndroidShadowView(cornerRadius: 16, elevation: 8).allowsHitTesting(false) }
        .foregroundStyle(ZTransferColors.primaryText)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { } // ConfirmCard consumes its blank area instead of dismissing the scrim.
    }

    // Material3 1.1.2 ButtonDefaults: 58x40 minimum visual bounds,
    // 8pt vertical padding, 24/12pt horizontal padding, 48pt touch height.
    private func actionButton(_ title: String, primary: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .zTransferTypography(.labelLarge)
                .foregroundStyle(primary ? ZTransferColors.onAccent : ZTransferColors.secondaryText)
                .padding(.horizontal, primary ? 24 : 12)
                .padding(.vertical, 8)
                .frame(minWidth: 58, minHeight: 40)
                .background {
                    if primary { RoundedRectangle(cornerRadius: 10).fill(tint) }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

private struct QueueScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// TransferScreen emptyQueue: reverse the tween's play time (rather than
/// swapping endpoints), preserving FastOutSlowIn's asymmetric reverse leg.
struct QueueEmptyMarkMotion {
    var opacity: Float
    var scale: Float

    static func sample(elapsedNanos: Int64) -> Self {
        let elapsed = max(0, elapsedNanos)
        let leg: Int64 = 2_400_000_000
        let cycle = elapsed % (2 * leg)
        let playTime = cycle <= leg ? cycle : 2 * leg - cycle
        let breathe = ZTransferAndroidMotion.tween(milliseconds: 2400)
        let alpha = breathe.animationSample(at: playTime, from: 0.42, to: 0.54, velocity: 0).value
        let scale = breathe.animationSample(at: playTime, from: 0.985, to: 1.015, velocity: 0).value
        let reveal = ZTransferAndroidMotion.tween(milliseconds: 340)
            .animationSample(at: elapsed, from: 0, to: 1, velocity: 0).value
        return Self(opacity: alpha * reveal, scale: scale)
    }
}

private struct QueueEmptyMark: View {
    @State private var visible = false
    var body: some View {
        QueueEmptyMarkSurface(active: visible)
            .frame(width: 58 * DoubleZMark.aspectRatio, height: 58)
            .allowsHitTesting(false)
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}

/// Keep the existing vector mark and environment. Only its transparent UIKit
/// ancestors animate: the renderer composites the same contents without a
/// display-link publisher rebuilding Canvas and the SwiftUI graph every frame.
struct QueueEmptyMarkSurface: UIViewRepresentable {
    var active = true
    func makeUIView(context: Context) -> QueueEmptyMarkNativeView { QueueEmptyMarkNativeView() }
    func updateUIView(_ view: QueueEmptyMarkNativeView, context: Context) {
        view.host.rootView = AnyView(DoubleZMark(tint: ZTransferColors.secondaryText)
            .environment(\.self, context.environment))
        view.configure(active: active)
    }
    static func dismantleUIView(_ view: QueueEmptyMarkNativeView, coordinator: ()) {
        view.stop()
        view.host.willMove(toParent: nil)
        view.host.removeFromParent()
    }
}

@MainActor
final class QueueEmptyMarkNativeView: UIView {
    let motionView = UIView()
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var active = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        motionView.backgroundColor = .clear
        motionView.isOpaque = false
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.clipsToBounds = false
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        addSubview(motionView)
        motionView.addSubview(host.view)
        layer.opacity = 0
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { stop(); return }
        contentScaleFactor = window.screen.scale
        motionView.contentScaleFactor = window.screen.scale
        host.view.contentScaleFactor = window.screen.scale
        if host.parent == nil {
            var candidate = next
            while let responder = candidate {
                if let parent = responder as? UIViewController {
                    parent.addChild(host); host.didMove(toParent: parent); break
                }
                candidate = responder.next
            }
        }
        if active { start() }
    }
    func configure(active: Bool) {
        self.active = active
        if active && window != nil { start() } else { stop() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // A presentation scale must not feed back into layout or bitmap size.
        motionView.bounds = CGRect(origin: .zero, size: bounds.size)
        motionView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        host.view.bounds = motionView.bounds
        host.view.center = CGPoint(x: motionView.bounds.midX, y: motionView.bounds.midY)
    }
    private func start() {
        guard motionView.layer.animation(forKey: "queue.breathe") == nil else { return }
        let now = CACurrentMediaTime()
        let forward = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        // Compose Reverse reverses play time, including the asymmetric curve.
        let reverse = CAMediaTimingFunction(controlPoints: 0.8, 0, 0.6, 1)
        func breathing(_ key: String, _ minimum: Double, _ maximum: Double) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = [minimum, maximum, minimum]
            animation.keyTimes = [0, 0.5, 1]
            animation.timingFunctions = [forward, reverse]
            animation.duration = 4.8
            return animation
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = 1
        motionView.layer.opacity = 0.42
        motionView.layer.transform = CATransform3DMakeScale(0.985, 0.985, 1)
        CATransaction.commit()
        let loop = CAAnimationGroup()
        loop.animations = [breathing("opacity", 0.42, 0.54), breathing("transform.scale", 0.985, 1.015)]
        loop.duration = 4.8
        loop.repeatCount = .infinity
        loop.beginTime = motionView.layer.convertTime(now, from: nil)
        motionView.layer.add(loop, forKey: "queue.breathe")
        // Multiplication by a separate ancestor retains the 340ms reveal
        // while breathing starts immediately, matching QueueEmptyMarkMotion.
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0; reveal.toValue = 1
        reveal.duration = 0.34
        reveal.timingFunction = forward
        reveal.beginTime = layer.convertTime(now, from: nil)
        layer.add(reveal, forKey: "queue.reveal")
    }
    func stop() {
        layer.removeAnimation(forKey: "queue.reveal")
        motionView.layer.removeAnimation(forKey: "queue.breathe")
    }
}

/// Android transferCardVisualState, shared by the card accent and badge.
/// Waiting/transferring take precedence over a retained generation error.
enum TransferCardVisualState: Hashable {
    case waiting, transferring, generating, completed, failed, cancelled

    init(item: TransferQueueItem) {
        if item.isGeneratingFrame { self = .generating }
        else if item.status == .waiting { self = .waiting }
        else if item.status == .transferring { self = .transferring }
        else if item.status == .failed || item.frameError != nil { self = .failed }
        else if item.status == .completed { self = .completed }
        else { self = .cancelled }
    }

    var color: Color {
        switch self {
        case .waiting: return ZTransferColors.accentYellow
        case .transferring: return ZTransferColors.accentBlue
        case .generating: return ZTransferColors.accentPurple
        case .completed: return ZTransferColors.statusConnected
        case .failed: return ZTransferColors.statusError
        case .cancelled: return ZTransferColors.secondaryText
        }
    }


}

/// One local display clock supplies both card surface and state marker.
/// Android animateColorAsState uses a 300ms FastOutSlowIn Oklab tween.
@MainActor
final class QueueCardAccentAnimator: NSObject, ObservableObject {
    @Published private(set) var value: UInt32?
    private var animation: ZTransferColorAnimation?
    private var link: CADisplayLink?
    func mount(_ color: UInt32) {
        stop()
        animation = .init(color, durationMilliseconds: 300)
        if value != color { value = color }
    }
    func update(_ color: UInt32) {
        guard animation != nil else { mount(color); return }
        animation?.retarget(color)
        guard animation?.isRunning == true, link == nil else { return }
        let link = ZTransferDisplayLink.make(owner: self) { $0.frame($1) }
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ link: CADisplayLink) {
        animation?.advance(Int64(link.timestamp * 1_000_000_000))
        if value != animation?.value { value = animation?.value }
        if animation?.isRunning != true { stop() }
    }
    func stop() { link?.invalidate(); link = nil }

    static func packed(_ color: Color, scheme: ColorScheme) -> UInt32 {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ZTransferAndroidColor.pack(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a))
    }
    static func color(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255,
              opacity: Double(value >> 24) / 255)
    }
}

/// Color frames only invalidate the surface/marker, not filenames, thumbnails,
/// action buttons, pill layout and progress inputs (performance ledger P10).
struct QueueCardAccentScope<Content: View>: View {
    @ObservedObject var animator: QueueCardAccentAnimator
    let fallback: UInt32
    @ViewBuilder let content: (Color) -> Content
    var body: some View { content(QueueCardAccentAnimator.color(animator.value ?? fallback)) }
}

/// Android TransferScreen runs its 200ms elapsed timer only while generation
/// is actually running. Keep the TimelineView identity across pause/completion
/// so the pill's retained content and exit animations aren't remounted.
struct QueueGenerationTimelineSchedule: TimelineSchedule {
    let running: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if running {
            return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 0.2).entries(from: startDate, mode: mode))
        }
        return AnySequence(CollectionOfOne(startDate))
    }
}

/// Only the active row subscribes to the 200ms progress stream. Inactive rows
/// and the page depend solely on structural queue snapshots.
struct QueueProgressScope<Content: View>: View {
    let model: TransferQueueProgressViewModel
    let active: Bool
    @ViewBuilder let content: (TransferActiveProgress?) -> Content
    var body: some View {
        if active { ActiveQueueProgressScope(model: model, content: content) }
        else { content(nil) }
    }
}

private struct ActiveQueueProgressScope<Content: View>: View {
    @ObservedObject var model: TransferQueueProgressViewModel
    @ViewBuilder let content: (TransferActiveProgress?) -> Content
    var body: some View { content(model.activeProgress) }
}

struct QueueItemView: View {
    let item: TransferQueueItem
    let session: CameraSession?
    var thumbnailRetryNudge: Bool = false
    let activeProgress: TransferActiveProgress?
    let isRemoving: Bool
    let isClearing: Bool
    let retryEnabled: Bool
    let onRetry: () -> Void
    let onWithdraw: () -> Void
    var onRemovalAbandoned: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @State private var accent = QueueCardAccentAnimator()
    @State private var collapseProgress: CGFloat = 1

    private var cardActionsVisible: Bool { !isRemoving && !isClearing }

    private var targetAccent: UInt32 {
        QueueCardAccentAnimator.packed(TransferCardVisualState(item: item).color, scheme: scheme)
    }

    var body: some View {
        ZStack {
            TransferCardProgressLayer(
                status: item.status,
                progress: displayedProgress,
                seed: item.id.uuidString
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .circular))
            HStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    QueueThumbnail(session: session, item: item, retryNudge: thumbnailRetryNudge)
                        .id(session.map(ObjectIdentifier.init))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    QueueTaskStatusBadge(item: item)
                }
                .frame(width: 72, height: 72)
                .padding(.trailing, 12)
                // Android TransferTaskCardContent: rowGap and pill spacing are 5dp.
                VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if item.hasCrop {
                        QueueCropIcon().fill(style: FillStyle(eoFill: true))
                            .frame(width: 14, height: 14)
                            .foregroundStyle(ZTransferColors.accentBlue)
                            .accessibilityLabel(AppLocalized.resource("crop_task"))
                    }
                    TransferFileTitle(name: item.file.fileName, cancelled: item.status == .cancelled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 5) {
                    TransferInfoPill(text: fileSizeText, color: ZTransferColors.secondaryText,
                                     respond: item.status == .transferring && speedText != nil)
                    QueuePillVisibility(visible: TransferQueueCardText(item: item).transferSkipped || speedText != nil, delay: 60) {
                        if TransferQueueCardText(item: item).transferSkipped {
                            TransferInfoPill(text: AppLocalized.resource("status_skipped"),
                                             color: ZTransferColors.secondaryText)
                        } else if let speedText {
                            TransferInfoPill(text: speedText, color: ZTransferColors.statusConnected,
                                             numericValue: item.status == .completed
                                                ? item.downloadMBps * 1024 * 1024
                                                : Double(displayedBytesPerSecond),
                                             respond: item.elapsedMs != nil)
                        }
                    }
                    QueuePillVisibility(visible: item.elapsedMs != nil, delay: 150) {
                        if let elapsed = item.elapsedMs {
                            TransferInfoPill(text: formatDuration(elapsed), color: ZTransferColors.accentBlue)
                        }
                    }
                }
                if let error = TransferQueueCardText(item: item).errorText {
                    Text(error).zTransferTypography(.labelMedium)
                        .foregroundStyle(ZTransferColors.statusError).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Group {
                    if let effectText {
                        HStack(spacing: 5) {
                            TransferInfoPill(text: effectText, color: ZTransferColors.accentPurple,
                                respond: item.isGeneratingFrame && !item.frameGenerationSkipped &&
                                    item.displayedFrameGenerationElapsedMs(now: PhotoGenerationClock.now()) != nil)
                            TimelineView(QueueGenerationTimelineSchedule(running:
                                item.isGeneratingFrame && item.frameGenerationStartedAtElapsedMs != nil)) { _ in
                                let presentation = TransferQueueCardText(item: item)
                                let elapsed = item.frameGenerationSkipped ? nil :
                                    item.displayedFrameGenerationElapsedMs(now: PhotoGenerationClock.now())
                                QueuePillVisibility(visible: presentation.generationWaiting || elapsed != nil, delay: 80) {
                                    TransferInfoPill(text: elapsed.map { formatDuration($0) } ?? "",
                                        color: ZTransferColors.accentYellow, waiting: presentation.generationWaiting)
                                }
                            }
                        }
                    }
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                QueuePillVisibility(visible: cardActionsVisible && item.canRetry && item.status != .cancelled,
                                    delay: 0, style: .retry) {
                    QueueRetryButton(action: onRetry)
                        .padding(.leading, 10)
                        .disabled(!retryEnabled)
                        .accessibilityLabel(AppLocalized.resource("retry"))
                        .accessibilityIdentifier("queue-retry-\(item.file.id)")
                        #if DEBUG
                        .onAppear { QueueClearInteractionTrace.shared.actionAppeared(fileID: item.file.id) }
                        #endif
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .modifier(QueueCardContentSize())
            // Android draws the sheen above the liquid fill, below card content.
            .background(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.08 : 0.10), .clear],
                                       startPoint: .top, endPoint: .bottom))
        }
        .background {
            QueueCardAccentScope(animator: accent, fallback: targetAccent) { color in
                ZTransferColors.surface.mix(with: color, by: 0.09, scheme: scheme)
                    .transaction { $0.animation = nil }
            }
        }
        .overlay(alignment: .leading) {
            // Android drawBehind marker: excluded from row measurement.
            QueueCardAccentScope(animator: accent, fallback: targetAccent) { color in
                RoundedRectangle(cornerRadius: 2.5, style: .circular)
                    .fill(color.opacity(0.65))
                    .frame(width: 2.5, height: 32)
                    .offset(x: 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transaction { $0.animation = nil }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .circular).strokeBorder(
            LinearGradient(colors: [Color.white.opacity(0.32),
                                    scheme == .dark ? .clear : Color.black.opacity(0.06),
                                    Color.black.opacity(0.08)], startPoint: .top, endPoint: .bottom),
            lineWidth: 1))
        .background {
            // TransferScreen: elevation 6dp, radius16, black .08/.12. Compose
            // quantizes these to 20/31 before HWUI's material light multiplier.
            AndroidShadowView(cornerRadius: 16, elevation: 6,
                              shadowColors: .init(ambientAlpha: 20, spotAlpha: 31))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .modifier(QueueCardSwipeModifier(
            enabled: QueueCardSwipeState.isEnabled(item: item, removing: isRemoving, clearing: isClearing),
            removing: isRemoving,
            onRemove: onWithdraw,
            onRemovalAbandoned: onRemovalAbandoned
        ))
        // TransferScreen: collapseHeight wraps padding(bottom = 8.dp).
        // Measure the gap with the card so removal collapses both together,
        // including the final row, without a leftover list-level gap.
        .padding(.bottom, 8)
        .modifier(QueueCardCollapse(progress: collapseProgress))
        .onAppear { accent.mount(targetAccent) }
        .onChange(of: targetAccent) { accent.update($0) }
        .onDisappear { accent.stop() }
        .onChange(of: isRemoving) { removing in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: removing ? 0.28 : 0.20)) {
                collapseProgress = removing ? 0 : 1
            }
        }
    }

    private var speedText: String? {
        if item.status == .completed, item.downloadMBps > 0 {
            return String(format: "%.1f MB/s", item.downloadMBps)
        }
        guard item.status == .transferring, displayedBytesPerSecond > 0 else { return nil }
        return transferSpeedText(displayedBytesPerSecond)
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
        TransferQueueCardText(item: item).fileSizeText(activeProgress: activeProgress)
    }

    private var effectText: String? { TransferQueueCardText(item: item).effectText }

}

/// TransferTaskCardContent: a generation error wins over a transfer error;
/// failure replaces the effect row, and skipped text needs an actual effect.
struct TransferQueueCardText {
    let item: TransferQueueItem
    /// Android d973f0f5: a reused original has no download duration. `skipped`
    /// can also describe a duplicate derived image after a real download, so
    /// it must never replace that download's speed/duration with this label.
    var transferSkipped: Bool {
        item.status == .completed && item.elapsedMs == nil && (item.skipped || item.outputURL != nil)
    }
    var generationWaiting: Bool {
        item.isGeneratingFrame && item.frameGenerationStartedAtElapsedMs == nil && !item.frameGenerationSkipped
    }

    func fileSizeText(activeProgress: TransferActiveProgress? = nil) -> String {
        let downloaded = activeProgress?.taskID == item.id ? activeProgress!.downloadedBytes : item.downloadedBytes
        let bytes = item.file.size == UInt64(UInt32.max) ? downloaded : item.file.size
        if item.file.size == UInt64(UInt32.max) && bytes == 0 { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    var errorText: String? {
        guard item.status == .failed || item.frameError != nil else { return nil }
        if let error = item.frameError {
            return AppLocalized.resource("local_photo_batch_failed") + ": " + error
        }
        return item.error ?? AppLocalized.resource("transfer_failed")
    }
    var effectText: String? {
        guard errorText == nil else { return nil }
        var parts: [String] = []
        if item.hasCrop { parts.append(AppLocalized.resource("crop_title")) }
        if item.cropEffectsSkipped {
            parts.append(AppLocalized.resource("crop_effects_skipped"))
            return item.frameGenerationSkipped ? AppLocalized.resource("status_skipped") : parts.joined(separator: " · ")
        }
        if let preset = item.effects?.photoFramePreset, item.effects?.photoFrameEnabled == true,
           let label = frameLabel(preset) {
            parts.append(item.effects?.photoFrameBorderEnabled == true ? label : AppLocalized.resource("photo_frame_watermark_short"))
        }
        if let filter = item.effects?.selectedFilter, item.effects?.photoFilterEnabled == true {
            // Android resolves built-in names by identity; imported presets keep their name.
            let name = Np3FilterCatalog.preset(id: filter.preset.id).map {
                AppLocalized.resource("photo_filter_builtin_" + $0.legacyID)
            } ?? filter.preset.name
            parts.append("\(name) \(filter.normalizedIntensityPercent)%")
        }
        guard !parts.isEmpty else { return nil }
        return item.frameGenerationSkipped ? AppLocalized.resource("status_skipped") : parts.joined(separator: " · ")
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
        case .filmNegative: return AppLocalized.resource("photo_frame_film_negative")
        case .parameterPoster: return AppLocalized.resource("photo_frame_parameter_poster")
        }
    }
}

/// FileListScreen.collapseHeight(clip = false): measure the full child on
/// every layout pass, report a rounded pixel height, and keep its top fixed.
private struct QueueCardCollapse: ViewModifier {
    let progress: CGFloat
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        QueueCardCollapseLayout(progress: progress, displayScale: displayScale) {
            content.opacity(min(1, max(0, progress)))
        }
    }
}

private struct QueueCardCollapseLayout: Layout {
    var progress: CGFloat
    let displayScale: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let full = child.sizeThatFits(proposal)
        let pixels = floor(full.height * displayScale + 0.5)
        let height = floor(pixels * min(1, max(0, progress)) + 0.5) / displayScale
        return CGSize(width: full.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        // Never feed the collapsed bounds back into the child's measurement.
        let full = child.sizeThatFits(proposal)
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(full))
    }
}

private struct QueueRetryButton: View {
    let action: () -> Void
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue

    private var size: CGFloat {
        let skin = ZTransferButtonSkin(storedValue: skinPreset)
        return skin == .frostedGlass || skin == .liquidGlass ? 28 : 48
    }

    var body: some View {
        Button(action: action) {
            RemoteEditorIcon(kind: .refresh).fill(ZTransferColors.accentBlue)
                .frame(width: 16, height: 16).frame(width: size, height: size)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: size / 2))
    }
}

/// Android's bulk-clear FAB. Individual cards use horizontal swipe removal.
private struct QueueBroomMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            var rotated = context
            rotated.translateBy(x: size.width / 2, y: size.height / 2)
            rotated.rotate(by: .degrees(45))
            rotated.translateBy(x: -size.width / 2, y: -size.height / 2)
            var handle = Path()
            handle.move(to: CGPoint(x: s * 0.5, y: s * 0.07))
            handle.addLine(to: CGPoint(x: s * 0.5, y: s * 0.44))
            rotated.stroke(handle, with: .color(color), style: StrokeStyle(lineWidth: s * 0.09, lineCap: .round))
            var band = Path()
            band.move(to: CGPoint(x: s * 0.395, y: s * 0.505))
            band.addLine(to: CGPoint(x: s * 0.605, y: s * 0.505))
            rotated.stroke(band, with: .color(color), style: StrokeStyle(lineWidth: s * 0.095, lineCap: .round))
            let starts: [CGFloat] = [0.425, 0.4625, 0.5, 0.5375, 0.575]
            let ends: [CGPoint] = [.init(x: 0.305, y: 0.865), .init(x: 0.365, y: 0.895),
                                  .init(x: 0.43, y: 0.915), .init(x: 0.5, y: 0.925), .init(x: 0.575, y: 0.925)]
            for index in 0..<5 {
                let x = starts[index], end = ends[index]
                var strand = Path()
                strand.move(to: CGPoint(x: x * s, y: s * 0.565))
                strand.addQuadCurve(to: CGPoint(x: end.x * s, y: end.y * s),
                    control: CGPoint(x: ((x + end.x) / 2 + 0.045) * s, y: ((0.565 + end.y) / 2 + 0.01) * s))
                rotated.stroke(strand, with: .color(color), style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
            }
            if s >= 22 {
                for (x, y, radius) in [(0.085, 0.775, 0.017), (0.175, 0.925, 0.012)] {
                    context.fill(Path(ellipseIn: CGRect(x: (x - radius) * s, y: (y - radius) * s,
                                                       width: radius * 2 * s, height: radius * 2 * s)), with: .color(color))
                }
            }
        }
    }
}

/// TransferScreen.AnimatedVisibility: initially active rows are immediately
/// opaque; completion delays 100ms then fades 220ms, failure fades 180ms.
/// Interrupted tweens use Compose Transition's default spring, preserving velocity.
struct QueueCardProgressVisibility {
    private(set) var visible: Bool
    private(set) var retained: Bool
    private(set) var alpha: ZTransferScalarAnimation
    var isRunning: Bool { alpha.isRunning }

    init(status: TransferStatus) {
        visible = status == .transferring
        retained = visible
        alpha = .init(value: visible ? 1 : 0)
    }
    mutating func update(_ status: TransferStatus) {
        let next = status == .transferring
        guard next != visible else { return }
        visible = next
        retained = true
        let spec: ZTransferAndroidMotion
        if alpha.isRunning { spec = .criticallyDampedSpring(stiffness: 1500) }
        else if !next && status == .completed { spec = .tween(milliseconds: 220, delayMilliseconds: 100) }
        else { spec = .tween(milliseconds: 180) }
        alpha.retarget(next ? 1 : 0, using: spec)
    }
    mutating func advance(_ nanos: Int64) {
        alpha.advance(frameNanos: nanos)
        if !visible && !isRunning { retained = false }
    }
}

@MainActor
final class QueueCardProgressVisibilityClock: ObservableObject {
    private(set) var motion: QueueCardProgressVisibility
    @Published private(set) var retained: Bool
    let opacity = AndroidAnimatedOpacity()
    private var link: CADisplayLink?
    var clockRunning: Bool { link != nil }

    init(status: TransferStatus) {
        motion = .init(status: status); retained = motion.retained
        opacity.update(motion.alpha.value)
    }
    func update(_ status: TransferStatus) {
        motion.update(status); publish()
        guard motion.isRunning, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.advance(Int64(frame.timestamp * 1_000_000_000))
        }
        link = next; next.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) {
        motion.advance(nanos); publish()
        if !motion.isRunning { link?.invalidate(); link = nil }
    }
    func reset(_ status: TransferStatus) {
        link?.invalidate(); link = nil
        motion = .init(status: status); publish()
    }
    private func publish() {
        if retained != motion.retained { retained = motion.retained }
        opacity.update(motion.alpha.value)
    }
}

private struct TransferCardProgressLayer: View {
    let status: TransferStatus
    let progress: Double
    let seed: String
    @StateObject private var visibility: QueueCardProgressVisibilityClock

    init(status: TransferStatus, progress: Double, seed: String) {
        self.status = status; self.progress = progress; self.seed = seed
        _visibility = StateObject(wrappedValue: QueueCardProgressVisibilityClock(status: status))
    }
    var body: some View {
        Group {
            if visibility.retained {
                LiquidTransferProgressFill(progress: transferCardProgressTarget(status: status, progress: progress),
                    seed: seed, waveEligible: transferCardWaveEligible(status: status))
                    .modifier(AndroidOpacity(opacity: visibility.opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
        .onAppear { visibility.update(status) }
        .onChange(of: status) { visibility.update($0) }
        .onDisappear { visibility.reset(status) }
    }
}

/// Android's transfer cards use a low-amplitude liquid fill instead of a
/// static progress bar. The phase is driven by TimelineView so progress
/// updates do not create a second task per card.
/// All four transfer surfaces use Android's critically damped progress spring.
/// TransferProgressMotion.kt: each identity starts at zero; accepted targets
/// only advance. Motion.progress is spring(180, dampingRatio=1, threshold=.0005).
struct SmoothTransferProgressMotion {
    private(set) var key: AnyHashable?
    private(set) var accepted: Float = 0
    private(set) var animation = ZTransferScalarAnimation(value: 0)

    mutating func update(target: Double, key: AnyHashable?) {
        if self.key != key {
            self.key = key
            accepted = 0
            animation = .init(value: 0)
        }
        let normalized = target.isFinite ? Float(min(max(target, 0), 1)) : 0
        accepted = max(accepted, normalized)
        guard accepted > animation.value, accepted != animation.target else { return }
        if !animation.isRunning { animation = .init(value: animation.value) }
        animation.retarget(accepted, using: .criticallyDampedSpring(stiffness: 180, threshold: 0.0005))
    }
    mutating func advance(_ nanos: Int64) { animation.advance(frameNanos: nanos) }
}

@MainActor
final class SmoothTransferProgressAnimator: ObservableObject {
    @Published private(set) var motion = SmoothTransferProgressMotion()
    private var link: CADisplayLink?
    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: SmoothTransferProgressAnimator?
        init(_ owner: SmoothTransferProgressAnimator) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(link)
        }
    }

    func update(target: Double, key: AnyHashable?) {
        motion.update(target: target, key: key)
        guard motion.animation.isRunning, link == nil else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    private func frame(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000))
        if !motion.animation.isRunning { link.invalidate(); self.link = nil }
    }
    func stop() {
        link?.invalidate(); link = nil
        motion = .init()
    }
}

#if DEBUG
/// Observes the running animator, rather than echoing the requested input.
struct SmoothTransferProgressObservation: Equatable {
    let key: String?
    let value: Float
}
struct SmoothTransferProgressObservationKey: PreferenceKey {
    static let defaultValue: SmoothTransferProgressObservation? = nil
    static func reduce(value: inout SmoothTransferProgressObservation?,
                       nextValue: () -> SmoothTransferProgressObservation?) {
        if let next = nextValue() { value = next }
    }
}
#endif

struct SmoothTransferProgress<Content: View>: View {
    let target: Double
    let resetKey: AnyHashable?
    @ViewBuilder let content: (Double) -> Content
    @State private var animator = SmoothTransferProgressAnimator()
    private struct Input: Equatable {
        let target: Double
        let key: AnyHashable?
    }
    private var input: Input { .init(target: target, key: resetKey) }
    var body: some View {
        TransferProgressContent(animator: animator, content: content)
            .onAppear { animator.update(target: target, key: resetKey) }
            .onChange(of: input) { next in
                animator.update(target: next.target, key: next.key)
            }
            .onDisappear { animator.stop() }
    }
}

/// Observe display frames only at the drawing leaf. A parent can retain the
/// animator in State across icon/content branches without redrawing its text,
/// glass material and layout on every progress frame.
struct TransferProgressContent<Content: View>: View {
    @ObservedObject var animator: SmoothTransferProgressAnimator
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(Double(animator.motion.animation.value))
            // Values already come from the explicit momentum-preserving spring.
            // A surrounding button/fade transaction must not animate them again.
            .transaction { $0.animation = nil }
            .background {
#if DEBUG
                Color.clear.preference(key: SmoothTransferProgressObservationKey.self,
                    value: SmoothTransferProgressObservation(
                        key: animator.motion.key?.base as? String,
                        value: animator.motion.animation.value))
#endif
            }
    }
}

struct LiquidTransferProgressFill: View {
    let progress: Double
    let seed: String
    var isCapsule = false
    var waveEligible = true
    var body: some View {
        SmoothTransferProgress(target: progress, resetKey: seed) { value in
            LiquidTransferProgressSurface(progress: value, seed: seed,
                                          isCapsule: isCapsule, waveEligible: waveEligible)
        }
    }
}

func liquidProgressWaveEnvelope(_ progress: Double) -> CGFloat {
    // Android computes each smoothStep operation in Float, including the
    // threshold-adjacent values that decide whether to mount the wave clock.
    let p = Float(progress.isFinite ? min(max(progress, 0), 1) : 0)
    func smooth(_ start: Float, _ end: Float) -> Float {
        let t = min(max((p - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }
    return CGFloat(smooth(0.05, 0.14) * (1 - smooth(0.90, 0.98)))
}

/// Drawing only: callers can retain their smoothing state while this surface
/// is absent (the top queue pill's icon branch does exactly that on Android).
struct LiquidTransferProgressSurface: View {
    let progress: Double
    let seed: String
    var isCapsule = false
    var waveEligible = true
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Group {
            if waveEligible && liquidProgressWaveEnvelope(progress) > 0.001 {
                LiquidTransferWave(progress: progress, seedPhase: seedPhase, isCapsule: isCapsule)
            } else {
                LiquidTransferShape(progress: progress, phase: 0, amplitude: 0, pixelScale: displayScale)
                    .fill(ZTransferColors.accentBlue.opacity(isCapsule ? 0.35 : 0.14))
            }
        }
        .allowsHitTesting(false)
    }
    private var seedPhase: CGFloat {
        let hash = seed.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        return CGFloat(hash & 0xffff) / 65535
    }
}

struct LiquidWavePhaseMotion {
    private var origin: Int64?
    private(set) var phase: CGFloat = 0
    mutating func advance(_ nanos: Int64, cycleMilliseconds: Int64) {
        if origin == nil { origin = nanos }
        let elapsed = max(0, nanos - origin!)
        let cycle = max(1, cycleMilliseconds) * 1_000_000
        let remainder = elapsed % cycle
        // VectorizedInfiniteRepeatableSpec Restart subtracts whole cycles;
        // FloatTweenSpec then computes its linear fraction in Float.
        phase = CGFloat(Float(remainder) / Float(cycle))
    }
}

@MainActor
private final class LiquidWavePhaseClock: ObservableObject {
    @Published private(set) var motion = LiquidWavePhaseMotion()
    private var link: CADisplayLink?
    private var cycleMilliseconds: Int64 = 2200

    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: LiquidWavePhaseClock?
        init(_ owner: LiquidWavePhaseClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.motion.advance(Int64(link.timestamp * 1_000_000_000), cycleMilliseconds: owner.cycleMilliseconds)
        }
    }
    func start(cycleMilliseconds: Int64) {
        guard link == nil else { return }
        self.cycleMilliseconds = cycleMilliseconds
        motion = .init()
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil; motion = .init() }
}

private struct LiquidTransferWave: View {
    let progress: Double
    let seedPhase: CGFloat
    let isCapsule: Bool
    @Environment(\.displayScale) private var displayScale
    @StateObject private var clock = LiquidWavePhaseClock()
    var body: some View {
        LiquidTransferShape(progress: progress, phase: clock.motion.phase,
                            seed: seedPhase, amplitude: isCapsule ? 2 : 3,
                            segments: isCapsule ? 8 : 12, spatialScale: isCapsule ? 1 : 0.55,
                            pixelScale: displayScale)
            .fill(ZTransferColors.accentBlue.opacity(isCapsule ? 0.35 : 0.14))
            .onAppear { clock.start(cycleMilliseconds: isCapsule ? 2200 : 2600) }
            .onDisappear { clock.stop() }
    }
}

// LiquidProgressFill.kt uses Float arguments; Kotlin/JVM sin(Float) widens
// the already-rounded angle to Double and narrows the result back to Float.
private let liquidProgressTwoPi: Float = 6.2831855
private func liquidProgressSin(_ angle: Float) -> Float { Float(sin(Double(angle))) }

func liquidProgressWaveUnitOffset(normalizedY: Float, phaseTurns: Float,
                                  seedTurns: Float, spatialScale: Float = 1) -> Float {
    let y = min(max(normalizedY, 0), 1) * max(spatialScale, 0)
    let time = phaseTurns * liquidProgressTwoPi
    let seed = seedTurns * liquidProgressTwoPi
    return 0.64 * liquidProgressSin(time + y * liquidProgressTwoPi * 1.15 + seed)
        + 0.24 * liquidProgressSin(-2 * time + y * liquidProgressTwoPi * 2.40 + seed * 0.73)
        + 0.12 * liquidProgressSin(3 * time + y * liquidProgressTwoPi * 3.35 + seed * 1.31)
}

struct LiquidTransferShape: Shape {
    var progress: Double
    var phase: CGFloat
    var seed: CGFloat = 0
    var amplitude: CGFloat = 3
    var segments: Int = 12
    var spatialScale: CGFloat = 0.55
    var pixelScale: CGFloat = 1
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let p = Float(progress.isFinite ? min(max(progress, 0), 1) : 0)
        guard p > 0 else { return Path() }
        let scale = pixelScale.isFinite && pixelScale > 0 ? pixelScale : 1
        // Compose Canvas operates in physical pixels. Convert back only when
        // handing the finished Float control points to SwiftUI's point path.
        let width = Float(rect.width * scale)
        let height = Float(rect.height * scale)
        let fillWidth = width * p
        func point(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(x) / scale, y: rect.minY + CGFloat(y) / scale)
        }
        let envelope = Float(liquidProgressWaveEnvelope(progress))
        guard envelope > 0.001, amplitude > 0 else {
            return Path(CGRect(origin: rect.origin,
                               size: CGSize(width: CGFloat(fillWidth) / scale,
                                            height: CGFloat(height) / scale)))
        }
        let time = Float(phase) * liquidProgressTwoPi
        let seedAngle = Float(seed) * liquidProgressTwoPi
        let breathing: Float = 0.90 + 0.10 * liquidProgressSin(2 * time + seedAngle)
        let waveAmplitude = max(Float(amplitude) * Float(scale), 0) * envelope * breathing
        func edge(_ y: Float) -> Float {
            let wave = liquidProgressWaveUnitOffset(normalizedY: y, phaseTurns: Float(phase),
                seedTurns: Float(seed), spatialScale: Float(spatialScale))
            return min(max(fillWidth + waveAmplitude * wave, 0), width)
        }
        let segmentCount = max(2, segments)
        let segmentHeight = height / Float(segmentCount)
        var path = Path()
        path.move(to: point(0, 0))
        var currentX = edge(0)
        var currentY: Float = 0
        path.addLine(to: point(currentX, currentY))
        for index in 1...segmentCount {
            let nextY = segmentHeight * Float(index)
            let nextX = edge(Float(index) / Float(segmentCount))
            path.addQuadCurve(to: point((currentX + nextX) / 2, (currentY + nextY) / 2),
                              control: point(currentX, currentY))
            currentX = nextX
            currentY = nextY
        }
        path.addQuadCurve(to: point(currentX, currentY), control: point(currentX, currentY))
        path.addLine(to: point(0, height))
        path.closeSubpath()
        return path
    }
}

/// Material ContentCut 24px, matching Android Icons.Default.ContentCut.
/// Source: google/material-design-icons/src/content/content_cut/materialicons/24px.svg.
private struct QueueCropIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 9.64, y: 7.64))
        p.addCurve(to: CGPoint(x: 10, y: 6), control1: CGPoint(x: 9.87, y: 7.14), control2: CGPoint(x: 10, y: 6.59))
        p.addCurve(to: CGPoint(x: 6, y: 2), control1: CGPoint(x: 10, y: 3.79), control2: CGPoint(x: 8.21, y: 2))
        p.addCurve(to: CGPoint(x: 2, y: 6), control1: CGPoint(x: 3.79, y: 2), control2: CGPoint(x: 2, y: 3.79))
        p.addCurve(to: CGPoint(x: 6, y: 10), control1: CGPoint(x: 2, y: 8.21), control2: CGPoint(x: 3.79, y: 10))
        p.addCurve(to: CGPoint(x: 7.64, y: 9.64), control1: CGPoint(x: 6.59, y: 10), control2: CGPoint(x: 7.14, y: 9.87))
        p.addLine(to: CGPoint(x: 10, y: 12))
        p.addLine(to: CGPoint(x: 7.64, y: 14.36))
        p.addCurve(to: CGPoint(x: 6, y: 14), control1: CGPoint(x: 7.14, y: 14.13), control2: CGPoint(x: 6.59, y: 14))
        p.addCurve(to: CGPoint(x: 2, y: 18), control1: CGPoint(x: 3.79, y: 14), control2: CGPoint(x: 2, y: 15.79))
        p.addCurve(to: CGPoint(x: 6, y: 22), control1: CGPoint(x: 2, y: 20.21), control2: CGPoint(x: 3.79, y: 22))
        p.addCurve(to: CGPoint(x: 10, y: 18), control1: CGPoint(x: 8.21, y: 22), control2: CGPoint(x: 10, y: 20.21))
        p.addCurve(to: CGPoint(x: 9.64, y: 16.36), control1: CGPoint(x: 10, y: 17.41), control2: CGPoint(x: 9.87, y: 16.86))
        p.addLine(to: CGPoint(x: 12, y: 14))
        p.addLine(to: CGPoint(x: 19, y: 21))
        p.addLine(to: CGPoint(x: 22, y: 21))
        p.addLine(to: CGPoint(x: 22, y: 20))
        p.addLine(to: CGPoint(x: 9.64, y: 7.64))
        p.closeSubpath()
        p.move(to: CGPoint(x: 6, y: 8))
        p.addCurve(to: CGPoint(x: 4, y: 6), control1: CGPoint(x: 4.9, y: 8), control2: CGPoint(x: 4, y: 7.11))
        p.addCurve(to: CGPoint(x: 6, y: 4), control1: CGPoint(x: 4, y: 4.89), control2: CGPoint(x: 4.9, y: 4))
        p.addCurve(to: CGPoint(x: 8, y: 6), control1: CGPoint(x: 7.1, y: 4), control2: CGPoint(x: 8, y: 4.89))
        p.addCurve(to: CGPoint(x: 6, y: 8), control1: CGPoint(x: 8, y: 7.11), control2: CGPoint(x: 7.1, y: 8))
        p.closeSubpath()
        p.move(to: CGPoint(x: 6, y: 20))
        p.addCurve(to: CGPoint(x: 4, y: 18), control1: CGPoint(x: 4.9, y: 20), control2: CGPoint(x: 4, y: 19.11))
        p.addCurve(to: CGPoint(x: 6, y: 16), control1: CGPoint(x: 4, y: 16.89), control2: CGPoint(x: 4.9, y: 16))
        p.addCurve(to: CGPoint(x: 8, y: 18), control1: CGPoint(x: 7.1, y: 16), control2: CGPoint(x: 8, y: 16.89))
        p.addCurve(to: CGPoint(x: 6, y: 20), control1: CGPoint(x: 8, y: 19.11), control2: CGPoint(x: 7.1, y: 20))
        p.closeSubpath()
        p.move(to: CGPoint(x: 12, y: 12.5))
        p.addCurve(to: CGPoint(x: 11.5, y: 12), control1: CGPoint(x: 11.72, y: 12.5), control2: CGPoint(x: 11.5, y: 12.28))
        p.addCurve(to: CGPoint(x: 12, y: 11.5), control1: CGPoint(x: 11.5, y: 11.72), control2: CGPoint(x: 11.72, y: 11.5))
        p.addCurve(to: CGPoint(x: 12.5, y: 12), control1: CGPoint(x: 12.28, y: 11.5), control2: CGPoint(x: 12.5, y: 11.72))
        p.addCurve(to: CGPoint(x: 12, y: 12.5), control1: CGPoint(x: 12.5, y: 12.28), control2: CGPoint(x: 12.28, y: 12.5))
        p.closeSubpath()
        p.move(to: CGPoint(x: 19, y: 3))
        p.addLine(to: CGPoint(x: 13, y: 9))
        p.addLine(to: CGPoint(x: 15, y: 11))
        p.addLine(to: CGPoint(x: 22, y: 4))
        p.addLine(to: CGPoint(x: 22, y: 3))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Material Schedule 24px path used by Android Icons.Default.Schedule.
/// Source: google/material-design-icons/src/action/schedule/materialicons/24px.svg.
private struct QueueWaitingClock: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 11.99, y: 2))
        p.addCurve(to: CGPoint(x: 2, y: 12), control1: CGPoint(x: 6.47, y: 2), control2: CGPoint(x: 2, y: 6.48))
        p.addCurve(to: CGPoint(x: 11.99, y: 22), control1: CGPoint(x: 2, y: 17.52), control2: CGPoint(x: 6.47, y: 22))
        p.addCurve(to: CGPoint(x: 22, y: 12), control1: CGPoint(x: 17.52, y: 22), control2: CGPoint(x: 22, y: 17.52))
        p.addCurve(to: CGPoint(x: 11.99, y: 2), control1: CGPoint(x: 22, y: 6.48), control2: CGPoint(x: 17.52, y: 2))
        p.closeSubpath()
        p.move(to: CGPoint(x: 12, y: 20))
        p.addCurve(to: CGPoint(x: 4, y: 12), control1: CGPoint(x: 7.58, y: 20), control2: CGPoint(x: 4, y: 16.42))
        p.addCurve(to: CGPoint(x: 12, y: 4), control1: CGPoint(x: 4, y: 7.58), control2: CGPoint(x: 7.58, y: 4))
        p.addCurve(to: CGPoint(x: 20, y: 12), control1: CGPoint(x: 16.42, y: 4), control2: CGPoint(x: 20, y: 7.58))
        p.addCurve(to: CGPoint(x: 12, y: 20), control1: CGPoint(x: 20, y: 16.42), control2: CGPoint(x: 16.42, y: 20))
        p.closeSubpath()
        p.move(to: CGPoint(x: 12.5, y: 7))
        for point in [CGPoint(x: 11, y: 7), CGPoint(x: 11, y: 13), CGPoint(x: 16.25, y: 16.15),
                      CGPoint(x: 17, y: 14.92), CGPoint(x: 12.5, y: 12.25)] { p.addLine(to: point) }
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// TransferInfoPill's LaunchedEffect(respond): initial true is quiet, a rising
/// edge snaps to one, contracts for 105ms, then returns with Motion.bouncy().
struct TransferPillResponseMotion {
    private(set) var responding: Bool
    private(set) var scale = ZTransferScalarAnimation(value: 1)
    private var contracting = false
    init(responding: Bool) { self.responding = responding }
    mutating func update(_ responding: Bool) {
        guard responding != self.responding else { return }
        self.responding = responding
        contracting = responding
        scale.reset(to: responding ? 1 : scale.value)
        if responding { scale.retarget(0.94, using: .tween(milliseconds: 105)) }
    }
    mutating func advance(_ nanos: Int64) {
        scale.advance(frameNanos: nanos)
        if contracting && !scale.isRunning {
            contracting = false
            scale.retarget(1, using: .bouncy,
                           atFrameNanos: nanos)
        }
    }
}

@MainActor
final class TransferPillResponseAnimator: NSObject, ObservableObject {
    @Published private(set) var motion: TransferPillResponseMotion
    @Published private(set) var widthMotion = QueuePillWidthMotion()
    private var link: CADisplayLink?
    private var lastWidth: (pixels: CGFloat, scale: CGFloat)?
    init(responding: Bool) { motion = .init(responding: responding) }
    func update(_ responding: Bool) {
        if responding != motion.responding { motion.update(responding) }
        schedule()
    }
    func measureWidth(_ width: CGFloat, scale: CGFloat) {
        guard width.isFinite, width >= 0, scale.isFinite, scale > 0 else { return }
        let pixels = floor(width * scale + 0.5)
        if lastWidth?.pixels != pixels || lastWidth?.scale != scale {
            lastWidth = (pixels, scale)
            widthMotion.measure(width, scale: scale)
        }
        schedule()
    }
    private func schedule() {
        if !motion.scale.isRunning && !widthMotion.isRunning { stop(); return }
        guard link == nil else { return }
        let link = ZTransferDisplayLink.make(owner: self) { $0.frame($1) }
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ link: CADisplayLink) {
        let nanos = Int64(link.timestamp * 1_000_000_000)
        if motion.scale.isRunning { motion.advance(nanos) }
        if widthMotion.isRunning { widthMotion.advance(nanos) }
        if !motion.scale.isRunning && !widthMotion.isRunning { stop() }
    }
    func mount(_ responding: Bool) {
        stop()
        motion = .init(responding: responding)
        schedule()
    }
    func unmount() { stop(); widthMotion = .init(); lastWidth = nil }
    func stop() { link?.invalidate(); link = nil }
}

/// The user requested smoother speed readouts on iOS (2026-10-17). Keep the
/// sampled value and formatting exact; animate only the glyph replacement.
/// Shared by the top capsule and the active queue card, with stable digit widths.
struct TransferNumericText: View {
    let text: String
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Text(text)
            } else if #available(iOS 17.0, *) {
                Text(text).contentTransition(.numericText(value: value))
            } else {
                Text(text).contentTransition(.opacity)
            }
        }
        .monospacedDigit()
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.24), value: text)
    }
}

private struct TransferInfoPill: View {
    let text: String
    let color: Color
    let numericValue: Double?
    let waiting: Bool
    let respond: Bool
    @State private var response: TransferPillResponseAnimator

    init(text: String, color: Color, numericValue: Double? = nil,
         waiting: Bool = false, respond: Bool = false) {
        self.text = text; self.color = color; self.waiting = waiting; self.respond = respond
        self.numericValue = numericValue
        _response = State(initialValue: TransferPillResponseAnimator(responding: respond))
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    // Android TransferInfoPill replaces glassSheen alpha before interpolation:
    // the resulting white endpoints are identical in light and dark themes.
    private var fill: LinearGradient {
        LinearGradient(colors: [
            color.opacity(0.10).mix(with: Color.white.opacity(0.15), by: 0.30, scheme: scheme),
            color.opacity(0.09), color.opacity(0.12)
        ], startPoint: .top, endPoint: .bottom)
    }
    private var edge: LinearGradient {
        LinearGradient(colors: [
            color.opacity(0.22).mix(with: Color.white.opacity(0.32), by: 0.45, scheme: scheme),
            color.opacity(0.16), color.opacity(0.25)
        ], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        Group {
            if waiting {
                QueueWaitingClock().fill(color, style: FillStyle(eoFill: true))
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(AppLocalized.resource("status_waiting"))
            } else if let numericValue {
                TransferNumericText(text: text, value: numericValue)
                    .zTransferTypography(.labelSmall).foregroundStyle(color)
            } else {
                Text(text).zTransferTypography(.labelSmall).foregroundStyle(color)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { response.measureWidth(geometry.size.width, scale: displayScale) }
                    .onChange(of: geometry.size.width) { response.measureWidth($0, scale: displayScale) }
                    .onChange(of: displayScale) { response.measureWidth(geometry.size.width, scale: $0) }
            }
        }
        .modifier(TransferPillAnimatedLayout(response: response, fill: fill, edge: edge))
        .lineLimit(1)
        .transaction { $0.animation = nil }
        .onAppear { response.mount(respond) }
        .onChange(of: respond) { response.update($0) }
        .onDisappear { response.unmount() }
    }
}

/// The width/response clock owns only layout and composition. Text, gradients
/// and intrinsic-size inputs are built once per actual content/theme change.
struct TransferPillAnimatedLayout: ViewModifier {
    @ObservedObject var response: TransferPillResponseAnimator
    let fill: LinearGradient
    let edge: LinearGradient
    func body(content: Content) -> some View {
        QueuePillWidthLayout(displayedWidth: response.widthMotion.width) { content }
            .clipped()
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .circular).strokeBorder(edge, lineWidth: 1))
            .scaleEffect(x: CGFloat(response.motion.scale.value), y: 1, anchor: .leading)
    }
}

private struct QueueThumbnail: View {
    let session: CameraSession?
    let item: TransferQueueItem
    let retryNudge: Bool
    @State private var image: UIImage?
    @Environment(\.colorScheme) private var scheme

    init(session: CameraSession?, item: TransferQueueItem, retryNudge: Bool) {
        self.session = session
        self.item = item
        self.retryNudge = retryNudge
        _image = State(initialValue: session?.memoryThumbnailImage(file: item.file))
    }

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                (scheme == .dark ? ZTransferColors.surface : Color(red: 230/255, green: 230/255, blue: 235/255))
                    .overlay {
                        RemoteEditorIcon(kind: .image).fill(ZTransferColors.secondaryText).frame(width: 22, height: 22)
                    }
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
        .task(id: retryNudge) {
            guard image == nil, let session else { return }
            if session.wirelessMode == .sta {
                for await _ in await session.thumbnailUpdates(handle: item.file.id) {
                    guard !Task.isCancelled else { return }
                    if let cached = try? await session.thumbnailImage(file: item.file, allowRemote: false) {
                        guard !Task.isCancelled else { return }
                        image = cached
                        return
                    }
                }
            } else if let image = try? await session.thumbnailImage(file: item.file) {
                guard !Task.isCancelled else { return }
                self.image = image
            }
        }
    }
}

#if DEBUG
/// Presentation-only fixture: renders the real card with controlled snapshots.
/// Queue lifecycle/byte accounting are covered separately by actor tests.
struct QueueCardPresentationHarness: View {
    @State private var phase = 0
    private let cropMode = ProcessInfo.processInfo.arguments.contains("--queue-card-crop-test")
    private let downloadMode = ProcessInfo.processInfo.arguments.contains("--queue-card-download-test")
    private let badgeMode = ProcessInfo.processInfo.arguments.contains("--queue-card-badge-test")
    private let widthMode = ProcessInfo.processInfo.arguments.contains("--queue-pill-width-test")
    private let visibilityMode = ProcessInfo.processInfo.arguments.contains("--queue-pill-visibility-test")
    @ObservedObject private var visibilityProbe = QueuePillVisibilityProbe.shared
    private var item: TransferQueueItem {
        var item = TransferQueueItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000079")!,
            file: CameraFile(id: 79, storageID: 1, format: 0x3801, size: UInt64(UInt32.max),
                fileName: downloadMode ? "A_VERY_LONG_CAMERA_CAPTURE_FILENAME_123456.JPG" : "GENERATION_123456.JPG",
                captureDate: nil, isProtected: false))
        item.status = .completed
        item.downloadedBytes = 2048
        if badgeMode {
            item.status = [.waiting, .transferring, .completed, .completed, .failed, .cancelled][phase]
            item.isGeneratingFrame = phase == 2
            return item
        }
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false
        if cropMode || downloadMode {
            let source = JpegCropSource(width: 16, height: 16, mcuWidth: 16, mcuHeight: 16, orientation: 1)
            item.cropTask = LosslessCropTask(fileID: item.file.id, recipe: .init(source: source,
                rect: .init(left: 0, top: 0, right: 16, bottom: 16)))
            if downloadMode {
                item.status = phase == 0 ? .waiting : phase == 1 ? .transferring : .completed
                item.downloadedBytes = phase == 2 ? 2048 : 0
                return item // Crop alone; no frame/filter effects.
            }
            effects.photoFilterEnabled = true
            effects.selectedFilter = .init(preset: PhotoFilterCatalog.presets[0], intensityPercent: 63)
            item.effects = effects
            item.cropEffectsSkipped = phase == 1
            if phase == 2 { item.status = .cancelled }
            return item
        }
        item.effects = effects
        item.isGeneratingFrame = phase == 0
        item.frameGenerationSkipped = phase == 1
        // Deliberately retain old timing/error data to exercise presentation precedence.
        item.frameGenerationAccumulatedMs = 1500
        if phase == 1 { item.frameGenerationElapsedMs = 1500 }
        if phase == 2 {
            item.status = .failed
            item.error = "TRANSFER_ERROR_MUST_BE_HIDDEN"
            item.frameError = "GENERATION_ERROR"
        }
        return item
    }
    private var activeProgress: TransferActiveProgress? {
        guard downloadMode, phase > 0 else { return nil }
        // Completion deliberately carries another task's progress: it must be ignored.
        return TransferActiveProgress(taskID: phase == 1 ? item.id : UUID(), fraction: 0,
            bytesPerSecond: 0, retainedBytesPerSecond: 0, downloadedBytes: phase == 1 ? 1024 : 9216)
    }
    var body: some View {
        VStack(spacing: 20) {
            if visibilityMode {
                HStack(spacing: 5) {
                    TransferInfoPill(text: "2 KB", color: ZTransferColors.secondaryText)
                    QueuePillVisibility(visible: phase == 1, delay: 60) {
                        if phase == 1 { TransferInfoPill(text: "10 MB/s", color: ZTransferColors.statusConnected) }
                    }
                    QueuePillVisibility(visible: phase == 1, delay: 150) {
                        if phase == 1 { TransferInfoPill(text: "1.2s", color: ZTransferColors.accentBlue) }
                    }
                    QueuePillVisibility(visible: phase == 1, delay: 80) {
                        TransferInfoPill(text: "2.4s", color: ZTransferColors.accentYellow)
                    }
                }
                .frame(width: 320, alignment: .leading)
                Text(visibilityProbe.summary).accessibilityIdentifier("queue-pill-visibility-trace")
                Text(visibilityProbe.reversalSummary).accessibilityIdentifier("queue-pill-reversal-trace")
            } else if widthMode {
                TransferInfoPill(text: phase == 0 ? "1 KB" : "123456789012345678901234567890 KB",
                                 color: ZTransferColors.accentYellow, waiting: phase == 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("queue-pill-width")
                    .frame(width: 120, alignment: .leading)
            } else {
                QueueItemView(item: item, session: nil, activeProgress: activeProgress,
                    isRemoving: false, isClearing: false, retryEnabled: false,
                    onRetry: {}, onWithdraw: {})
            }
            Button("Next state") { phase = (phase + 1) % (badgeMode ? 6 : 3) }
                .accessibilityIdentifier("queue-card-next-state")
            if badgeMode {
                Text("badge-phase-\(phase)").accessibilityIdentifier("queue-card-badge-phase")
            }
            Spacer()
        }.padding(20)
        .onChange(of: visibilityProbe.reverseRequested) { requested in
            if visibilityMode && requested { phase = 1 }
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--queue-card-dark") ? .dark : .light)
    }
}
#endif
