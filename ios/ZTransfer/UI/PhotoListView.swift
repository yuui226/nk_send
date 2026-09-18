import SwiftUI
import UIKit

func normalizedThumbnailColumns(_ value: Int) -> Int {
    min(max(value, 2), 4)
}

/// A return target only counts as visible when every edge is inside the
/// scrollable photo viewport. `intersects` is intentionally insufficient: a
/// clipped first/last row still needs a small corrective scroll before the
/// preview collapses into it.
func photoFrameIsFullyVisible(_ frame: CGRect, in viewport: CGRect,
                              tolerance: CGFloat = 0.5) -> Bool {
    guard frame.width > 0, frame.height > 0,
          viewport.width > 0, viewport.height > 0,
          !frame.isNull, !frame.isInfinite,
          !viewport.isNull, !viewport.isInfinite else { return false }
    return frame.minX >= viewport.minX - tolerance &&
        frame.maxX <= viewport.maxX + tolerance &&
        frame.minY >= viewport.minY - tolerance &&
        frame.maxY <= viewport.maxY + tolerance
}

@preconcurrency
private struct PhotoListTopControlsTransition: AnimatableModifier {
    var progress: CGFloat
    let hiddenOffset: CGFloat
    let hiddenScale: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(x: hiddenOffset * (1 - progress))
            .scaleEffect(hiddenScale + (1 - hiddenScale) * progress, anchor: .leading)
    }
}

private enum QueueExecutionVisualMode: Hashable {
    case start, pause
}

private struct PhotoListWorkspaceTransition: AnimatableModifier {
    var progress: CGFloat
    let horizontalFraction: CGFloat
    let fadedOpacity: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .opacity(fadedOpacity + (1 - fadedOpacity) * progress)
                .offset(x: proxy.size.width * horizontalFraction * (1 - progress))
        }
    }
}

private let photoQueueWorkspaceAnimation =
    // Android Motion.queuePageSlide: 320 ms FastOutSlowIn. A fixed-duration
    // curve also reverses cleanly from the current frame without inheriting
    // stale spring velocity after a rapid back action.
    Animation.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.32)

/// The default SwiftUI hold is 500ms. The photo grid is a deliberate
/// tap/hold mode switch, so use the user-approved shorter threshold while
/// retaining a small movement allowance to avoid firing during a scroll.
let photoPreviewLongPressDuration = 0.25

private struct PhotoReturnFocusPulse: ViewModifier {
    let trigger: Int
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Android applies the return emphasis in the render layer: two
            // 5.5% scale pulses plus a faint white wash. Keeping it outside
            // layout prevents the surrounding grid from being remeasured.
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(Double(progress) * 0.11))
                    .allowsHitTesting(false)
            }
            .scaleEffect(1 + 0.055 * progress)
            .task(id: trigger) {
                let reset = Transaction(animation: nil)
                withTransaction(reset) { progress = 0 }
                guard trigger > 0 else { return }
                for _ in 0..<2 {
                    withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.11)) { progress = 1 }
                    do { try await Task.sleep(nanoseconds: 110_000_000) }
                    catch { return }
                    withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.155)) { progress = 0 }
                    do { try await Task.sleep(nanoseconds: 155_000_000) }
                    catch { return }
                    do { try await Task.sleep(nanoseconds: 35_000_000) }
                    catch { return }
                }
            }
    }
}

private struct PhotoTransferExit: ViewModifier {
    let exiting: Bool
    let onFinished: () -> Void
    @State private var progress: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.82 + 0.18 * progress)
            .allowsHitTesting(!exiting)
            .task(id: exiting) {
                guard exiting else {
                    progress = 1
                    return
                }
                progress = 1
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)) { progress = 0 }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                onFinished()
            }
    }
}

private struct PhotoCellReveal: ViewModifier {
    let active: Bool
    let trigger: Int
    let delay: UInt64
    @State private var progress: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .opacity(active ? progress : 1)
            .scaleEffect(active ? 0.94 + 0.06 * progress : 1)
            .task(id: "\(trigger)|\(active)") {
                guard active else { progress = 1; return }
                let transaction = Transaction(animation: nil)
                withTransaction(transaction) { progress = 0 }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)) { progress = 1 }
            }
    }
}

private struct PhotoDateGridHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PhotoListViewportPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

private struct PhotoListTopControlsBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

// The floating header is intentionally a little taller than Android's 36dp
// control. At 40pt it keeps the same compact silhouette on iPhone while the
// visible material and its hit region no longer feel vertically compressed.
private let photoListTopControlsHeight: CGFloat = 40
private let photoListCompactButtonWidth: CGFloat = 40

private func photoGridCellTransition(burstMember: Bool, cameraRemoval: Bool) -> AnyTransition {
    if burstMember {
        return .asymmetric(
            insertion: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)),
            removal: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15))
        )
    }
    if cameraRemoval {
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96))
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16))
        )
    }
    return .identity
}

/// Android's FileListScreen shows the remote entry introduction across the
/// first six app starts, incrementing only when the expansion actually begins.
let remoteEntryIntroMaxPlays = 6

func isRemoteEntryIntroEligible(playCount: Int) -> Bool {
    max(0, playCount) < remoteEntryIntroMaxPlays
}

@MainActor struct PhotoListView: View {
    @StateObject private var model: PhotoListViewModel
    @StateObject private var queueModel: TransferQueueViewModel
    @ObservedObject private var directoryStore: DirectoryAccessStore
    let effectsStore: PhotoEffectsStore
    let isSessionConnected: Bool
    let onRetrySTA: () -> Void
    let onTransportLost: (CameraSession) -> Void
    // RootView creates this workspace with an established session and keeps it
    // mounted after transport loss; isSessionConnected tracks live connectivity.
    private let session: CameraSession
    @AppStorage("tap_to_preview") private var tapToPreview = false
    @State private var selectedFile: CameraFile?
    @State private var previewAnchor: CGRect?
    @State private var photoListScrollProxy: ScrollViewProxy?
    @State private var previewReturnFileID: UInt32?
    @State private var previewReturnNonce = 0
    @State private var showingFilter = false
    @State private var showingQueue = false
    @State private var queueTopControlsVisible = false
    @State private var queueWorkspaceTransitionNonce = 0
    @AppStorage("defer_transfer_start") private var deferTransferStart = false
    @AppStorage("organize_transfers_by_date") private var organizeByDate = false
    @AppStorage("collapse_burst_photos") private var collapseBurstPhotos = true
    @AppStorage("thumbnail_columns") private var thumbnailColumns = 3
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.frostedGlass.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedBurstIDs: Set<String> = []
    @State private var previousBurstGroups: [BurstPhotoGroup] = []
    @State private var collapsedDays: Set<String> = []
    @State private var presentedSections: [PhotoDaySection] = []
    @State private var presentedCameraFiles: [CameraFile] = []
    @State private var cameraRemovalAffectedDays: Set<String> = []
    @State private var cameraRemovalTask: Task<Void, Never>?
    @State private var collapsingDay: String?
    @State private var collapsingDayKeepCount = 0
    @State private var dateCollapseProgress: CGFloat = 1
    @State private var dateGridHeights: [String: CGFloat] = [:]
    @State private var dateAnimationTask: Task<Void, Never>?
    @State private var recentlyExpandedDay: String?
    @State private var revealTick = 0
    @State private var filterRevealWindow = false
    @State private var revealWindowTask: Task<Void, Never>?
    @State private var burstAnimationBusy = false
    @State private var burstReflowActive = false
    @State private var activeBurstReflowID: String?
    @State private var burstAnimationTask: Task<Void, Never>?
    @State private var showTopButton = false
    @State private var photoListScrollOffset: CGFloat = 0
    @State private var internalShowingRemote = false
    private let remotePresentation: Binding<Bool>?
    private var showingRemote: Bool {
        get { remotePresentation?.wrappedValue ?? internalShowingRemote }
        nonmutating set {
            if let remotePresentation { remotePresentation.wrappedValue = newValue }
            else { internalShowingRemote = newValue }
        }
    }
    @State private var remoteEntryHint: String?
    @State private var remoteEntryHintID = UUID()
    @State private var remoteExpandedAwayFromTop = false
    @State private var remoteIntroExpanded = false
    @State private var remoteIntroHandledForEntry = false
    @AppStorage("remote_entry_intro_play_count") private var remoteEntryIntroPlayCount = 0
    @State private var showingSettings = false
    @State private var transferDirectoryAttention = false
    @State private var signalExpanded = false
    @State private var effectPreviewSource: UIImage?
    @State private var effectPreviewExif: PhotoExif?
    @State private var effectPreviewGeneration = 0
    @State private var effectPreviewRequested = false
    @State private var effectPreviewFileKey: String?
    @State private var effectPreviewAttemptKey: String?
    @State private var effectPreviewLoadingKey: String?
    @State private var topControlsVisible = true
    @State private var cellBounds: [UInt32: CGRect] = [:]
    @State private var photoListViewportBounds: CGRect = .zero
    @State private var photoListTopControlsBounds: CGRect = .zero
    @State private var sectionEnqueueBounds: [String: CGRect] = [:]
    @State private var queueTargetBounds: CGRect = .zero
    @State private var queueFlights: [PhotoListQueueFlight] = []
    @State private var heldFlightCount = 0
    @State private var heldFlightBaselineRemaining: Int?
    @State private var queueImpact = 0

    init(session: CameraSession, queue: TransferQueue, directory: DirectoryAccessStore = DirectoryAccessStore(), effectsStore: PhotoEffectsStore = PhotoEffectsStore(), isSessionConnected: Bool = true, onRetrySTA: @escaping () -> Void = {}, remotePresentation: Binding<Bool>? = nil, onTransportLost: @escaping (CameraSession) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: PhotoListViewModel.cached(session: session,
                                                                      onTransportLost: { onTransportLost(session) }))
        _queueModel = StateObject(wrappedValue: TransferQueueViewModel(queue: queue))
        _directoryStore = ObservedObject(wrappedValue: directory)
        self.effectsStore = effectsStore; self.isSessionConnected = isSessionConnected
        self.onRetrySTA = onRetrySTA
        self.remotePresentation = remotePresentation
        self.onTransportLost = onTransportLost; self.session = session
    }

    private var columns: [GridItem] {
        // Android clamps the persisted preference to two through four columns;
        // the grid uses the same 6dp inter-cell spacing on both axes.
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6),
              count: normalizedThumbnailColumns(thumbnailColumns))
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZTransferColors.background.ignoresSafeArea()
            if showingQueue {
                TransferQueueView(model: queueModel, session: session, directory: directoryStore,
                                  isSessionConnected: isSessionConnected,
                                  onRetrySTA: onRetrySTA,
                                  showsTopControls: false,
                                  onNavigateBack: dismissQueuePage)
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalFraction: 1, fadedOpacity: 0.72),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalFraction: 1, fadedOpacity: 0.72)
                    ),
                    removal: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalFraction: 1, fadedOpacity: 0.72),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalFraction: 1, fadedOpacity: 0.72)
                    )
                ))
                .zIndex(1)
            } else {
            ScrollViewReader { reader in
                ScrollView(showsIndicators: false) {
                    Color.clear.frame(height: 1).id("photo-list-top")
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: PhotoListScrollOffsetKey.self,
                                                       value: proxy.frame(in: .named("photo-list-scroll")).minY)
                            }
                        }
                    // Android keeps 10dp on both sides of every date header:
                    // previous group's last row → header and header → first row.
                    LazyVStack(alignment: .leading, spacing: 10) {
                    // The scanner publishes each newest-first metadata batch
                    // before fetching that batch's thumbnails. Render those
                    // rows immediately, even while the remaining catalog is
                    // loading; otherwise the first 12 stay hidden until the
                    // entire camera scan completes.
                    if !presentedSections.isEmpty {
                            ForEach(presentedSections) { section in
                                let allEntries = photoGridEntries(
                                    section.files,
                                    burstIDByFile: model.burstIDByFile,
                                    collapse: collapseBurstPhotos,
                                    expandedIDs: expandedBurstIDs
                                )
                                let collapsingThis = collapsingDay == section.day
                                let displayedEntries = collapsingThis
                                    ? Array(allEntries.prefix(collapsingDayKeepCount))
                                    : allEntries
                                VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                Button {
                                    toggleDateSection(section, entries: allEntries)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(section.day == PhotoCatalogGrouping.unknownDay
                                             ? AppLocalized.resource("unknown_date")
                                             : formatDateHeader(section.day))
                                            .zTransferText(size: ZTransferMetrics.body, weight: .bold)
                                            .foregroundStyle(ZTransferColors.primaryText)
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(ZTransferColors.accentBlue)
                                            .rotationEffect(.degrees(
                                                collapsedDays.contains(section.day) || collapsingThis ? 0 : 180
                                            ))
                                        Text("\(section.files.count)")
                                            .zTransferText(size: ZTransferMetrics.caption)
                                            .foregroundStyle(ZTransferColors.secondaryText)
                                            .monospacedDigit()
                                    }
                                    // Android's date control is an intrinsic
                                    // width capsule; a trailing Spacer here made
                                    // it stretch across the entire grid.
                                    .padding(.horizontal, 14)
                                    .frame(height: 28)
                                }
                                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
                                Spacer(minLength: 0)
                                Button {
                                    enqueueSection(section.files, source: sectionEnqueueBounds[section.day])
                                } label: {
                                    Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(ZTransferColors.accentBlue)
                                        .frame(width: 40, height: 28)
                                }
                                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: PhotoListSectionEnqueueBoundsPreferenceKey.self,
                                            value: [section.day: proxy.frame(in: .global)]
                                        )
                                    }
                                }
                                }
                                if !collapsedDays.contains(section.day) || collapsingThis {
                                    LazyVGrid(columns: columns, spacing: 6) {
                                        ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { cellIndex, entry in
                                        let file = entry.firstFile
                                        let transferExiting = entry.isPhoto &&
                                            model.exitingTransferredFileIDs.contains(file.id)
                                        let activeBurstMember = burstReflowActive && entry.isPhoto &&
                                            model.burstIDByFile[file.id] == activeBurstReflowID
                                        VStack(alignment: .leading, spacing: 0) {
                                            if case let .burst(group) = entry {
                                                BurstThumbnailView(session: session, group: group,
                                                                   allowRemoteThumbnails: selectedFile == nil,
                                                                   transferred: group.files.allSatisfy { model.transferredFileIDs.contains($0.id) },
                                                                   expanded: expandedBurstIDs.contains(group.id),
                                                                   onExpand: { toggleBurst(group.id) },
                                                                   onEnqueue: {
                                                                       enqueueSection(group.files, source: cellBounds[file.id])
                                                                   })
                                            } else {
                                            CameraThumbnailView(session: session, file: file,
                                                                    allowRemoteThumbnail: selectedFile == nil,
                                                                    transferred: model.transferredFileIDs.contains(file.id),
                                                                    inBurst: model.burstIDByFile[file.id] != nil,
                                                                    queueTask: queueModel.task(for: file.id),
                                                                    progressModel: queueModel.progressModel)
                                            }
                                        }
                                        // The grid proposes a width but may let a
                                        // child determine the row height. Lock the
                                        // cell itself to a square before gestures
                                        // and overlays are applied.
                                        .aspectRatio(1, contentMode: .fill)
                                        .frame(maxWidth: .infinity, minHeight: 0)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .id(entry.id)
                                        .contentShape(Rectangle())
                                        .background {
                                            GeometryReader { proxy in
                                                Color.clear.preference(
                                                    key: PhotoListCellBoundsPreferenceKey.self,
                                                    value: [file.id: proxy.frame(in: .global)]
                                                )
                                            }
                                        }
                                        .modifier(PhotoReturnFocusPulse(
                                            trigger: previewReturnFileID == file.id ? previewReturnNonce : 0
                                        ))
                                        .modifier(PhotoTransferExit(exiting: transferExiting) {
                                            finishTransferredExit(file.id)
                                        })
                                        .modifier(PhotoCellReveal(
                                            active: recentlyExpandedDay == section.day || filterRevealWindow,
                                            trigger: revealTick,
                                            delay: UInt64(min(cellIndex, 18)) * 15_000_000
                                        ))
                                        .transition(photoGridCellTransition(
                                            burstMember: activeBurstMember,
                                            cameraRemoval: cameraRemovalAffectedDays.contains(section.day)
                                        ))
                                        .onTapGesture { handleTap(entry, file: file) }
                                        .onLongPressGesture(
                                            minimumDuration: photoPreviewLongPressDuration,
                                            maximumDistance: 12
                                        ) {
                                            guard !burstAnimationBusy, collapsingDay == nil,
                                                  cameraRemovalAffectedDays.isEmpty else { return }
                                            handleLongPress(entry, file: file)
                                        }

                                    }
                                }
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: PhotoDateGridHeightPreferenceKey.self,
                                            value: [section.day: proxy.size.height]
                                        )
                                    }
                                }
                                .frame(
                                    height: collapsingThis
                                        ? max(0, (dateGridHeights[section.day] ?? 0) * dateCollapseProgress)
                                        : nil,
                                    alignment: .top
                                )
                                .opacity(collapsingThis ? dateCollapseProgress : 1)
                                .clipped()
                                }
                                }
                                .transaction { transaction in
                                    if !cameraRemovalAffectedDays.isEmpty &&
                                        !cameraRemovalAffectedDays.contains(section.day) &&
                                        !burstReflowActive {
                                        transaction.animation = nil
                                    }
                                }
                            }
                    } else {
                        if session.isUSB && !isSessionConnected {
                            PhotoListUSBDisconnectedState()
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 32)
                                .padding(.top, 150)
                        } else {
                            switch model.loadState {
                            case .idle, .loading:
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 48)
                            case let .failed(message):
                                Text(message).zTransferText(size: ZTransferMetrics.body).padding()
                            case .loaded:
                                PhotoListEmptyState(filterActive: model.filter.isActive,
                                                    usb: session.isUSB,
                                                    onClearFilter: model.clearFilter)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 150)
                            }
                        }
                    }
                    // Match Android's 12dp list inset so thumbnails align with
                    // the floating top controls instead of leaving a wider gutter.
                    }.padding(.horizontal, 12).padding(.top, 8)
                }
                .coordinateSpace(name: "photo-list-scroll")
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .allowsHitTesting(false)
                            .preference(
                                key: PhotoListViewportPreferenceKey.self,
                                value: proxy.frame(in: .global)
                            )
                    }
                }
                .onAppear { photoListScrollProxy = reader }
                .onPreferenceChange(PhotoListViewportPreferenceKey.self) { bounds in
                    photoListViewportBounds = bounds
                }
                .onPreferenceChange(PhotoListCellBoundsPreferenceKey.self) { bounds in
                    // Lazy-grid cells unregister when they leave composition.
                    // Keep only the current preference snapshot so preview
                    // dismissal never flies toward a stale off-screen frame.
                    cellBounds = bounds
                }
                .onPreferenceChange(PhotoListSectionEnqueueBoundsPreferenceKey.self) { bounds in
                    sectionEnqueueBounds = bounds
                }
                .onPreferenceChange(PhotoDateGridHeightPreferenceKey.self) { heights in
                    for (day, height) in heights where height > 0 { dateGridHeights[day] = height }
                }
                .onPreferenceChange(PhotoListScrollOffsetKey.self) { value in
                    photoListScrollOffset = value
                    showTopButton = value < -360
                    if value < -2 {
                        withAnimation(ZTransferMotion.standard) {
                            remoteIntroExpanded = false
                            remoteExpandedAwayFromTop = false
                        }
                    }
                }
                // Android's photo grid has no pull-to-refresh action. Adding
                // SwiftUI refreshable made a downward drag restart the camera
                // scan and thumbnail pipeline while the user was just scrolling.
                .overlay(alignment: .bottomTrailing) {
                    if showTopButton {
                        Button {
                            withAnimation(ZTransferMotion.standard) { reader.scrollTo("photo-list-top", anchor: .top) }
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                                .foregroundStyle(ZTransferColors.primaryText)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                        .padding(.trailing, 18).padding(.bottom, 22)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .overlay(alignment: .bottomLeading) { remoteEntryOverlay }
                // Keep a stable viewport slot while the real controls live
                // outside the ScrollView's gesture arena.
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Reserve the same list viewport as Android, but never put
                    // interactive controls inside the ScrollView's gesture
                    // arena. The actual header is a sibling of both pages.
                    Color.clear
                        .frame(height: photoListTopControlsHeight)
                        .allowsHitTesting(false)
                }
                // The two workspace pages are a horizontal pair. The files
                // page enters from the left when returning from the queue and
                // uses Android's one-third parallax plus opacity hand-off.
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalFraction: -1 / 3, fadedOpacity: 0.5),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalFraction: -1 / 3, fadedOpacity: 0.5)
                    ),
                    removal: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalFraction: -1 / 3, fadedOpacity: 0.5),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalFraction: -1 / 3, fadedOpacity: 0.5)
                    )
                ))
                .zIndex(0)
            }
            }
            if selectedFile != nil { previewOverlay }
            workspaceTopControls
            queueFlightOverlay
        }
        .onPreferenceChange(PhotoListQueueTargetPreferenceKey.self) { queueTargetBounds = $0 }
        .task {
            if presentedSections.isEmpty {
                presentedSections = model.sections
                presentedCameraFiles = model.availableFiles
            }
            await session.setPreferHighThroughputTransfers(!showingRemote)
            queueModel.attach(session: session, directory: directoryStore.directoryURL)
            model.setNewMediaHandler { files in
                guard UserDefaults.standard.bool(forKey: "auto_transfer_new_media"),
                      let directory = directoryStore.directoryURL else { return }
                let deferStart = UserDefaults.standard.bool(forKey: "defer_transfer_start")
                queueModel.enqueueAutomatic(files, session: session, directory: directory,
                                            autoStart: !deferStart, organizeByDate: organizeByDate,
                                            effects: effectsStore.settings)
            }
            model.load()
        }
        // Android's MainScreen LaunchedEffect runs once when its owner enters
        // composition as well as on later changes. A plain onChange misses an
        // already-running queue when this view is rebuilt for a recovered
        // CameraSession, allowing catalog/thumbnail work to compete with the
        // transfer. task(id:) provides the same initial synchronization and
        // cancels a stale write if the busy state flips again immediately.
        .task(id: queueModel.snapshot.isTransferring) {
            let busy = queueModel.snapshot.isTransferring
            model.setTransferBusy(busy)
            await session.setTransfersBusy(busy)
        }
        .task {
            guard isRemoteEntryIntroEligible(playCount: remoteEntryIntroPlayCount),
                  !remoteIntroHandledForEntry else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled,
                  !remoteIntroHandledForEntry,
                  photoListScrollOffset >= -2,
                  selectedFile == nil,
                  !showingQueue else { return }
            remoteIntroHandledForEntry = true
            remoteEntryIntroPlayCount = max(0, remoteEntryIntroPlayCount) + 1
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
                remoteIntroExpanded = true
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.24)) {
                remoteIntroExpanded = false
            }
        }
        .onChange(of: showingRemote) { remote in
            // MainActivity.shouldPreferHighThroughputTransfers: both files and
            // transfer routes enable this; monitoring disables it.
            Task { await session.setPreferHighThroughputTransfers(!remote) }
        }
        .onDisappear {
            cameraRemovalTask?.cancel()
            dateAnimationTask?.cancel()
            revealWindowTask?.cancel()
            burstAnimationTask?.cancel()
            Task { await session.setPreferHighThroughputTransfers(false) }
        }
        .onChange(of: collapseBurstPhotos) { enabled in
            burstAnimationTask?.cancel()
            burstAnimationTask = nil
            burstAnimationBusy = false
            burstReflowActive = false
            activeBurstReflowID = nil
            if !enabled { expandedBurstIDs.removeAll() }
        }
        .onChange(of: model.sections) { updatePresentedSections($0) }
        .onChange(of: model.availableDayKeys) { valid in
            // Filters can temporarily hide complete date groups. Only an
            // authoritative catalog change may retire a remembered choice.
            collapsedDays = collapsedDays.intersection(valid)
        }
        .onChange(of: model.burstGroups) { current in
            expandedBurstIDs = reconciledExpandedBurstIDs(previousGroups: previousBurstGroups,
                                                           currentGroups: current,
                                                           expandedIDs: expandedBurstIDs)
            previousBurstGroups = current
        }
        .onChange(of: model.exitingTransferredFileIDs) { exiting in
            guard !exiting.isEmpty else { return }
            let composedPhotoIDs = Set(model.sections.flatMap { section -> [UInt32] in
                guard !collapsedDays.contains(section.day) else { return [] }
                return photoGridEntries(section.files, burstIDByFile: model.burstIDByFile,
                                        collapse: collapseBurstPhotos,
                                        expandedIDs: expandedBurstIDs).compactMap { entry in
                    guard case let .photo(file) = entry else { return nil }
                    return file.id
                }
            })
            for id in exiting.subtracting(composedPhotoIDs) { model.finishTransferredExit(id) }
        }
        .onChange(of: model.availableFiles.count) { _ in
            // Android retains this demand when Settings opens before the
            // first metadata batch and retries when a candidate appears.
            if effectPreviewRequested { requestEffectPreview() }
            model.refreshTransferredIDs(directory: directoryStore.directoryURL, organizeByDate: organizeByDate)
        }
        .onChange(of: directoryStore.directoryURL) { directory in
            queueModel.attach(session: session, directory: directory)
            model.refreshTransferredIDs(directory: directory, organizeByDate: organizeByDate)
        }
        .onChange(of: organizeByDate) { _ in
            model.refreshTransferredIDs(directory: directoryStore.directoryURL, organizeByDate: organizeByDate)
        }
        .onChange(of: queueModel.snapshot.items) { items in
            model.recordTransferredOriginals(items)
        }
        .onChange(of: queueModel.snapshot.invalidatedDirectory) { invalidated in
            // Handle the actual invalidation once. A historical failed card
            // must never clear a different directory the user just selected.
            if let invalidated, invalidated == directoryStore.directoryURL {
                directoryStore.clear()
            }
        }
        .onChange(of: showingSettings) { isShowing in
            if !isShowing { transferDirectoryAttention = false }
        }
        .onChange(of: selectedFile) { file in
            if file == nil {
                // Android: fade-in 220ms after 30ms, with the slide/scale
                // completing at 260ms.  The single SwiftUI transition keeps
                // the three properties on one timeline and preserves the
                // same leading anchor.
                withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.26).delay(0.03)) {
                    topControlsVisible = true
                }
            } else {
                // Android: fade-out 150ms while the slide/scale completes at
                // 210ms.  Keep queue controls outside this state machine.
                withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.21)) {
                    topControlsVisible = false
                }
            }
        }
        .fullScreenCover(isPresented: $internalShowingRemote) {
            RemoteView(session: session,
                       recordingDirectory: directoryStore.directoryURL,
                       isSessionConnected: isSessionConnected,
                       onRetrySTA: onRetrySTA,
                       onPreparing: { await model.pauseForRemote() },
                       onStopped: { transportLost in
                           // A transport failure tears down this mounted
                           // session and reconnects in place. Do not
                           // start a second scan against the invalid PTP
                           // channel while the replacement is opening.
                           await model.resumeAfterRemote(isConnected: isSessionConnected && !transportLost)
                       },
                       onTransportLost: {
                           // Android keeps monitor navigation mounted
                           // during a dropped session so its STA signal
                           // control can request immediate recovery.
                           onTransportLost(session)
                       })
        }
        .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
            if let anchor = anchors[.settings] {
                SettingsPopupOverlay(
                    isPresented: $showingSettings,
                    showPhotoEffectsEntry: true,
                    effectsStore: effectsStore,
                    directory: directoryStore,
                    anchor: anchor,
                    requestTransferDirectoryAttention: transferDirectoryAttention,
                    effectPreviewSource: effectPreviewSource,
                    effectPreviewExif: effectPreviewExif,
                    onEffectPreviewRequested: requestEffectPreview
                )
            }
            if let anchor = anchors[.filter] {
                PhotoFilterPopupOverlay(
                    isPresented: $showingFilter,
                    anchor: anchor,
                    initial: model.filter,
                    availableExtensions: model.availableFilterExtensions.isEmpty
                        ? [".jpg", ".nef", ".mp4"]
                        : model.availableFilterExtensions,
                    availableStorageSlots: model.availableStorageSlots.count > 1
                        ? model.availableStorageSlots : [],
                    suggestedDate: model.latestKnownCaptureDay,
                    onChange: applyFilter
                )
            }
        }
    }

    @ViewBuilder private var previewOverlay: some View {
        let files = model.sections.flatMap(\.files)
        PhotoPreviewView(session: session, queueModel: queueModel, files: files,
                         burstIDByFile: model.burstIDByFile,
                         transferredFileIDs: model.transferredFileIDs, selectedFile: $selectedFile,
                         directory: directoryStore.directoryURL,
                         organizeByDate: organizeByDate,
                         queueTarget: queueTargetBounds == .zero ? nil : queueTargetBounds,
                         initialAnchor: previewAnchor,
                         initialExpandedBurstIDs: expandedBurstIDs,
                         collapseBursts: collapseBurstPhotos,
                         onBurstChanged: { id, expanded in
                             if expanded { expandedBurstIDs.insert(id) }
                             else { expandedBurstIDs.remove(id) }
                         }) { file in
            guard directoryStore.directoryURL != nil else {
                selectedFile = nil
                requestTransferDirectory()
                return false
            }
            if !deferTransferStart {
                queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL, organizeByDate: organizeByDate, effects: effectsStore.settings)
            } else {
                queueModel.enqueue(file, organizeByDate: organizeByDate, effects: effectsStore.settings)
            }
            return true
        } onEnqueueBurst: { burstFiles in
            guard directoryStore.directoryURL != nil else {
                selectedFile = nil
                requestTransferDirectory()
                return false
            }
            if !deferTransferStart, let directory = directoryStore.directoryURL {
                queueModel.enqueue(burstFiles, autoStart: session, directory: directory,
                                   organizeByDate: organizeByDate, effects: effectsStore.settings)
            } else {
                queueModel.enqueue(burstFiles, organizeByDate: organizeByDate, effects: effectsStore.settings)
            }
            return true
        } onQueueFlightStarted: { count in
            beginQueueFlightHold(count)
        } onQueueFlightFinished: { count in
            finishQueueFlightHold(count, caught: true)
        } onQueueFlightCancelled: { count in
            finishQueueFlightHold(count, caught: false)
        } prepareDismissTarget: { file in
            await preparePreviewDismissTarget(file)
        } onDismiss: { returnFile in
            selectedFile = nil
            previewAnchor = nil
            guard let returnFile else { return }
            previewReturnNonce &+= 1
            let nonce = previewReturnNonce
            previewReturnFileID = returnFile.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 760_000_000)
                if previewReturnNonce == nonce { previewReturnFileID = nil }
            }
        }
        .onAppear { model.pauseForPreview() }
        .onDisappear {
            model.resumeAfterPreview()
            model.wakeThumbnailFill()
        }
    }

    private var photoListTopLeftControls: some View {
        HStack(spacing: 8) {
            Button {
                ZTransferHaptics.shared.tick()
                transferDirectoryAttention = false
                showingSettings = true
            } label: {
                DoubleZMark(tint: ZTransferColors.primaryText)
                    .frame(width: 20 * DoubleZMark.aspectRatio, height: 20)
                    .padding(.horizontal, 12)
                    .frame(height: photoListTopControlsHeight)
            }
            .buttonStyle(ZTransferGlassButtonStyle(
                cornerRadius: 22,
                materialContentColor: ZTransferColors.accentYellow,
                prominentPressFeedback: true
            ))
            .geniePopupAnchor(.settings)
            .accessibilityIdentifier("popup-trigger-settings")

            Button {
                if session.isUSB {
                    guard isSessionConnected else { return }
                    withAnimation(signalExpanded
                                  ? .timingCurve(0.4, 0, 0.2, 1, duration: 0.22)
                                  : .spring(response: 0.42, dampingFraction: 0.72)) {
                        signalExpanded.toggle()
                    }
                } else if session.wirelessMode == .sta {
                    if !isSessionConnected { onRetrySTA() }
                }
            } label: {
                HStack(spacing: signalExpanded ? 5 : 0) {
                    PhotoListSignalIcon(isUSB: session.isUSB,
                                        wirelessMode: session.wirelessMode,
                                        connected: isSessionConnected)
                    if signalExpanded && session.isUSB && isSessionConnected {
                        Text(AppLocalized.resource("connection_usb"))
                            .zTransferTypography(.labelSmall, weight: .medium)
                            .foregroundStyle(ZTransferColors.accentBlue)
                    }
                }
                // All compact top controls except the Z mark are exactly
                // 40pt wide, matching Android's compact-button baseline.
                // Horizontal padding is introduced only for the intentional
                // expanded USB label state.
                .padding(.horizontal, signalExpanded ? 10 : 0)
                .frame(
                    width: signalExpanded ? nil : photoListCompactButtonWidth,
                    height: photoListTopControlsHeight
                )
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))

            let filterPalette = zTransferButtonAccentPalette(
                skin: .init(storedValue: skinPreset),
                scheme: colorScheme,
                active: ZTransferColors.accentYellow
            )
            Button {
                ZTransferHaptics.shared.tick()
                showingFilter.toggle()
            } label: {
                PhotoListFilterIcon(
                    active: model.filter.isActive,
                    color: model.filter.isActive ? filterPalette.active : filterPalette.inactive
                )
                    .frame(width: 20, height: 20)
                    .frame(width: photoListCompactButtonWidth,
                           height: photoListTopControlsHeight)
            }
            .buttonStyle(ZTransferGlassButtonStyle(
                cornerRadius: 22,
                active: model.filter.isActive,
                activeColor: filterPalette.material,
                activeOutline: true,
                materialContentColor: model.filter.isActive
                    ? filterPalette.active
                    : filterPalette.inactive,
                prominentPressFeedback: true
            ))
            .geniePopupAnchor(.filter)
            .accessibilityIdentifier("popup-trigger-filter")
        }
        .transition(.asymmetric(
            insertion: .modifier(
                active: PhotoListTopControlsTransition(progress: 0, hiddenOffset: -40, hiddenScale: 0.94),
                identity: PhotoListTopControlsTransition(progress: 1, hiddenOffset: -40, hiddenScale: 0.94)
            ),
            removal: .modifier(
                active: PhotoListTopControlsTransition(progress: 0, hiddenOffset: -40, hiddenScale: 0.96),
                identity: PhotoListTopControlsTransition(progress: 1, hiddenOffset: -40, hiddenScale: 0.96)
            )
        ))
    }

    /// The complete workspace header is one fixed-height sibling of the two
    /// horizontally transitioning pages. Its only interactive descendants are
    /// the visible controls themselves; no full-screen positioning layer can
    /// win the gesture arena ahead of a button.
    private var workspaceTopControls: some View {
        HStack(spacing: 8) {
            if queueTopControlsVisible {
                queuePageTopControls
            } else if !showingQueue && topControlsVisible {
                photoListTopLeftControls
            }

            Spacer(minLength: 0)
            queueTopRightControls
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: photoListTopControlsHeight, alignment: .top)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .allowsHitTesting(false)
                    .preference(
                        key: PhotoListTopControlsBoundsPreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
            }
        }
        .zIndex(3)
        .animation(ZTransferMotion.standard, value: queueModel.snapshot.items.count)
        .onPreferenceChange(PhotoListTopControlsBoundsPreferenceKey.self) {
            photoListTopControlsBounds = $0
        }
    }

    /// Android keeps the queue page's back/signal group outside the moving
    /// page. It fades in only after the 320 ms page slide has settled, and
    /// disappears immediately when returning so it never overlaps the list
    /// header that is still sliding into place.
    private var queuePageTopControls: some View {
        HStack(spacing: 8) {
            Button(action: dismissQueuePage) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: photoListCompactButtonWidth,
                           height: photoListTopControlsHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))

            Button {
                if session.isUSB {
                    guard isSessionConnected else { return }
                    withAnimation(signalExpanded
                                  ? .timingCurve(0.4, 0, 0.2, 1, duration: 0.22)
                                  : .spring(response: 0.42, dampingFraction: 0.72)) {
                        signalExpanded.toggle()
                    }
                } else if session.wirelessMode == .sta && !isSessionConnected {
                    onRetrySTA()
                }
            } label: {
                HStack(spacing: signalExpanded ? 5 : 0) {
                    PhotoListSignalIcon(isUSB: session.isUSB,
                                        wirelessMode: session.wirelessMode,
                                        connected: isSessionConnected)
                    if signalExpanded && session.isUSB && isSessionConnected {
                        Text(AppLocalized.resource("connection_usb"))
                            .zTransferTypography(.labelSmall, weight: .medium)
                            .foregroundStyle(ZTransferColors.accentBlue)
                    }
                }
                .padding(.horizontal, signalExpanded ? 10 : 0)
                .frame(
                    width: signalExpanded ? nil : photoListCompactButtonWidth,
                    height: photoListTopControlsHeight
                )
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
        }
        .transition(.opacity)
    }

    private func presentQueuePage() {
        guard !showingQueue else { return }
        queueWorkspaceTransitionNonce &+= 1
        let nonce = queueWorkspaceTransitionNonce
        queueTopControlsVisible = false
        withAnimation(photoQueueWorkspaceAnimation) { showingQueue = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard showingQueue, queueWorkspaceTransitionNonce == nonce else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.14)) {
                queueTopControlsVisible = true
            }
        }
    }

    private func dismissQueuePage() {
        guard showingQueue else { return }
        queueWorkspaceTransitionNonce &+= 1
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.08)) {
            queueTopControlsVisible = false
        }
        withAnimation(photoQueueWorkspaceAnimation) { showingQueue = false }
    }

    /// Android keeps queue execution and the queue pill outside the files ↔
    /// transfer page transition. Reusing this group in both pages preserves
    /// one source of truth for start/pause availability and pill animation.
    private var queueTopRightControls: some View {
        HStack(spacing: 8) {
            let executionMode = queueExecutionMode
            if let executionMode {
                Button {
                    switch executionMode {
                    case .pause:
                        guard !queueModel.snapshot.pauseAfterCurrent else { return }
                        ZTransferHaptics.shared.tick()
                        queueModel.pause()
                    case .start:
                        guard let directory = directoryStore.directoryURL else { return }
                        ZTransferHaptics.shared.tick()
                        queueModel.start(session: session, directory: directory)
                    }
                } label: {
                    ZStack {
                        Image(systemName: executionMode == .start ? "play.fill" : "pause.fill")
                            // SF Symbols' filled play triangle has more visual
                            // mass than Android's 21dp Material PlayArrow. Use
                            // 17pt so it stays visually restrained after the
                            // top control grows to 40pt; pause remains 18pt.
                            .font(.system(size: executionMode == .start ? 17 : 18, weight: .bold))
                            .foregroundStyle(executionMode == .start
                                             ? ZTransferColors.accentBlue
                                             : ZTransferColors.accentYellow)
                            .id(executionMode)
                            .transition(.opacity.combined(with: .scale(scale: 0.72)))
                    }
                    .frame(width: photoListCompactButtonWidth,
                           height: photoListTopControlsHeight)
                    .contentShape(Circle())
                }
                // Physical Android themes keep the fixed queue material. The
                // user-approved iOS-only Liquid Glass theme includes every
                // control in this queue cluster so the pair reads as one
                // native system family on iOS 26+.
                .buttonStyle(ZTransferGlassButtonStyle(
                    cornerRadius: 22,
                    followsSkin: ZTransferButtonSkin(storedValue: skinPreset) == .liquidGlass
                ))
                .disabled(executionMode == .start && directoryStore.directoryURL == nil)
                .opacity(executionMode == .start && directoryStore.directoryURL == nil ? 0.45 : 1)
                .accessibilityLabel(AppLocalized.resource(
                    executionMode == .start
                        ? "cd_start_transfers"
                        : (queueModel.snapshot.pauseAfterCurrent
                           ? "cd_pause_after_current_scheduled"
                           : "cd_pause_after_current")
                ))
                .transition(.opacity.combined(with: .scale(scale: 0.72)))
            }

            Button {
                    presentQueuePage()
                } label: {
                    LiveQueuePill(
                        snapshot: queueModel.snapshot,
                        progressModel: queueModel.progressModel,
                        heldCount: heldFlightCount,
                        heldBaselineRemaining: heldFlightBaselineRemaining
                    )
                }
                .buttonStyle(QueuePillButtonStyle())
                // Measure the visible capsule itself. Its right edge is fixed
                // by the trailing HStack even while its width springs, so the
                // flight cannot drift to a synthetic/fallback anchor.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PhotoListQueueTargetPreferenceKey.self,
                            value: proxy.frame(in: .global)
                        )
                    }
                }
                .accessibilityLabel(AppLocalized.resource("cd_transfer"))
        }
        .modifier(QueueControlsCatchEffect(trigger: queueImpact))
    }

    private var queueExecutionMode: QueueExecutionVisualMode? {
        let waitingCount = queueModel.snapshot.items.reduce(into: 0) { count, item in
            if item.status == .waiting { count += 1 }
        }
        let hasClaimedCurrent = queueModel.snapshot.items.contains { $0.status == .transferring }
        // Auto-start publishes isTransferring before its serial worker claims
        // the first item. Product-wise that first item is already the current
        // transfer, not a user-visible queued item, so never count it as a
        // reason to show PAUSE.
        let scheduledCurrentCount = queueModel.snapshot.isTransferring && !hasClaimedCurrent ? 1 : 0
        // A queued task is not visually available until its flight lands in
        // the pill. In immediate-transfer mode this suppresses implementation
        // snapshots without changing the semantics: the transfer has already
        // started and only tasks behind the current one are "waiting".
        let actualDownloadRemaining = queueModel.snapshot.items.reduce(into: 0) { count, item in
            if item.status == .waiting || item.status == .transferring { count += 1 }
        }
        let hiddenInFlightCount = queueHiddenFlightCount(actualRemaining: actualDownloadRemaining)
        let landedWaitingCount = max(
            0,
            waitingCount - scheduledCurrentCount - hiddenInFlightCount
        )
        guard landedWaitingCount > 0 else { return nil }
        if queueModel.snapshot.isTransferring { return .pause }
        // START belongs to a deliberately deferred/paused queue. Automatic
        // mode owns its worker immediately and must never expose its brief
        // scheduling snapshot as a manual-start state.
        return deferTransferStart || queueModel.snapshot.pauseAfterCurrent ? .start : nil
    }

    /// Android requests the latest visible file on entering Settings: publish
    /// its cached thumbnail first, then upgrade the same identity to the FHD
    /// preview and EXIF. A late response for an older file is discarded.
    private func requestEffectPreview() {
        effectPreviewRequested = true
        guard let file = model.latestEffectPreviewFile else { return }
        let key = "\(file.id)|\(file.fileName)|\(file.size)|\(file.captureDate ?? "")"
        guard effectPreviewFileKey != key,
              effectPreviewAttemptKey != key,
              effectPreviewLoadingKey != key else { return }
        effectPreviewLoadingKey = key
        effectPreviewGeneration &+= 1
        let generation = effectPreviewGeneration
        Task {
            if let image = session.memoryThumbnailImage(file: file) {
                if Task.isCancelled {
                    await MainActor.run {
                        guard generation == effectPreviewGeneration else { return }
                        effectPreviewLoadingKey = nil
                    }
                    return
                }
                await MainActor.run {
                    guard generation == effectPreviewGeneration else { return }
                    effectPreviewSource = image
                }
            }
            guard generation == effectPreviewGeneration else { return }
            let result: (Data?, PhotoExif?)
            do {
                result = try await session.effectPreviewAndExif(file: file)
            } catch {
                await MainActor.run {
                    guard generation == effectPreviewGeneration else { return }
                    effectPreviewLoadingKey = nil
                }
                model.wakeThumbnailFill()
                return
            }
            // Releasing the effect slot re-enables background filling. Wake a
            // worker that yielded while this sample owned the channel.
            model.wakeThumbnailFill()
            guard let previewData = result.0 else {
                await MainActor.run {
                    guard generation == effectPreviewGeneration else { return }
                    effectPreviewLoadingKey = nil
                    effectPreviewAttemptKey = key
                }
                return
            }
            if Task.isCancelled {
                await MainActor.run {
                    guard generation == effectPreviewGeneration else { return }
                    effectPreviewLoadingKey = nil
                }
                return
            }
            await MainActor.run {
                guard generation == effectPreviewGeneration else { return }
                effectPreviewLoadingKey = nil
                effectPreviewFileKey = key
                effectPreviewExif = result.1
                effectPreviewSource = UIImage(data: previewData)
            }
        }
    }

    @ViewBuilder
    private var remoteEntryOverlay: some View {
        let remoteExpanded = photoListScrollOffset >= -2 || remoteExpandedAwayFromTop || remoteIntroExpanded
        let introText = AppLocalized.resource("remote_entry_intro")
            .replacingOccurrences(of: "\\n", with: "\n")
        VStack(alignment: .leading, spacing: 8) {
            if let remoteEntryHint {
                Text(remoteEntryHint)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ZTransferColors.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Button {
                if remoteExpanded {
                    openRemote()
                } else {
                    ZTransferHaptics.shared.tick()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
                        remoteExpandedAwayFromTop = true
                    }
                }
            } label: {
                HStack(spacing: remoteIntroExpanded ? 6 : 0) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 24, height: 24)
                    if remoteIntroExpanded {
                        Text(introText)
                            .font(.system(size: 10, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(remoteIntroExpanded ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                .frame(width: remoteIntroExpanded ? 108 : 44, height: 44)
            }
            .buttonStyle(ZTransferGlassButtonStyle(
                cornerRadius: 26,
                active: remoteIntroExpanded,
                activeColor: ZTransferColors.accentBlue,
                activeOutline: remoteIntroExpanded
            ))
        }
        .padding(.leading, remoteExpanded ? 18 : -6)
        .padding(.bottom, 22)
        .scaleEffect(remoteExpanded ? 1 : 0.88, anchor: .leading)
        .rotationEffect(.degrees(remoteExpanded ? 0 : -3.5), anchor: .leading)
        .animation(.spring(response: 0.34, dampingFraction: 0.58), value: remoteExpanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.58), value: remoteIntroExpanded)
        .animation(ZTransferMotion.standard, value: remoteEntryHint)
    }

    private func openRemote() {
        // Android requires the shared transfer/recording destination before
        // monitor entry. Local recording uses this same directory, so opening
        // RemoteView first would only defer the failure until record is tapped.
        guard directoryStore.directoryURL != nil else {
            requestTransferDirectory()
            return
        }
        // Android keeps the PTP channel exclusive while a transfer worker is
        // active. Do the same here instead of allowing live view to collide
        // with an in-flight download and surface a session error.
        guard !queueModel.snapshot.isTransferring else {
            let hintID = UUID()
            remoteEntryHintID = hintID
            withAnimation(ZTransferMotion.standard) {
                remoteEntryHint = AppLocalized.resource("remote_blocked_transfer")
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled, remoteEntryHintID == hintID else { return }
                withAnimation(ZTransferMotion.standard) { remoteEntryHint = nil }
            }
            return
        }
        withAnimation(ZTransferMotion.standard) { showingRemote = true }
    }

    private func toggleBurst(_ id: String) {
        guard !burstAnimationBusy, collapsingDay == nil,
              cameraRemovalAffectedDays.isEmpty else { return }
        burstAnimationTask?.cancel()
        burstAnimationBusy = true
        burstReflowActive = true
        activeBurstReflowID = id
        burstAnimationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                if expandedBurstIDs.contains(id) { expandedBurstIDs.remove(id) }
                else { expandedBurstIDs.insert(id) }
            }
            try? await Task.sleep(nanoseconds: 348_000_000)
            guard !Task.isCancelled else { return }
            burstReflowActive = false
            activeBurstReflowID = nil
            burstAnimationBusy = false
            burstAnimationTask = nil
        }
    }

    private func updatePresentedSections(_ target: [PhotoDaySection]) {
        let currentCameraFiles = model.availableFiles
        let canAnimateRemoval = isSessionConnected && model.hasCompletedFileScan && !model.isLoadingFiles
        let removedDays = canAnimateRemoval
            ? publishedCameraRemovalDays(previous: presentedCameraFiles, current: currentCameraFiles)
            : []
        presentedCameraFiles = currentCameraFiles

        guard !removedDays.isEmpty else {
            presentedSections = target
            if !canAnimateRemoval {
                cameraRemovalTask?.cancel()
                cameraRemovalTask = nil
                cameraRemovalAffectedDays.removeAll()
            }
            return
        }

        cameraRemovalAffectedDays.formUnion(removedDays)
        cameraRemovalTask?.cancel()
        cameraRemovalTask = Task { @MainActor in
            // Arm the existing cells first so their exit and placement nodes
            // observe the same starting frame as Android's LazyGrid.
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.28)) {
                presentedSections = target
            }
            try? await Task.sleep(nanoseconds: 328_000_000)
            guard !Task.isCancelled else { return }
            cameraRemovalAffectedDays.removeAll()
            cameraRemovalTask = nil
        }
    }

    private func finishTransferredExit(_ fileID: UInt32) {
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.28)) {
            model.finishTransferredExit(fileID)
        }
    }

    private func applyFilter(_ filter: PhotoFilterState) {
        revealTick &+= 1
        recentlyExpandedDay = nil
        filterRevealWindow = true
        revealWindowTask?.cancel()
        let tick = revealTick
        revealWindowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, revealTick == tick else { return }
            filterRevealWindow = false
            revealWindowTask = nil
        }
        model.setFilter(filter)
    }

    private func toggleDateSection(_ section: PhotoDaySection, entries: [PhotoGridEntry]) {
        guard collapsingDay == nil, !burstAnimationBusy,
              cameraRemovalAffectedDays.isEmpty else { return }
        if collapsedDays.contains(section.day) {
            filterRevealWindow = false
            collapsedDays.remove(section.day)
            recentlyExpandedDay = section.day
            revealTick &+= 1
            revealWindowTask?.cancel()
            let day = section.day
            let tick = revealTick
            revealWindowTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled, revealTick == tick,
                      recentlyExpandedDay == day else { return }
                recentlyExpandedDay = nil
                revealWindowTask = nil
            }
            return
        }

        let viewport = UIScreen.main.bounds
        let lastVisible = entries.indices.last { index in
            guard let bounds = cellBounds[entries[index].firstFile.id] else { return false }
            return bounds.intersects(viewport)
        }
        guard let lastVisible else {
            collapsedDays.insert(section.day)
            return
        }
        dateAnimationTask?.cancel()
        recentlyExpandedDay = nil
        collapsingDay = section.day
        collapsingDayKeepCount = min(entries.count, lastVisible + 1 + columns.count)
        dateCollapseProgress = 1
        dateAnimationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                dateCollapseProgress = 0
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            collapsedDays.insert(section.day)
            collapsingDay = nil
            collapsingDayKeepCount = 0
            dateCollapseProgress = 1
            dateAnimationTask = nil
        }
    }

    private func enqueueSection(_ files: [CameraFile], source: CGRect?) {
        guard directoryStore.directoryURL != nil else { requestTransferDirectory(); return }
        guard let first = files.first else { return }
        ZTransferHaptics.shared.tick()
        beginQueueFlightHold(files.count)
        startListQueueFlight(for: first, count: files.count, from: source, packFiles: files)
        if deferTransferStart {
            queueModel.enqueue(files, organizeByDate: organizeByDate, effects: effectsStore.settings)
        } else {
            queueModel.enqueue(files, autoStart: session, directory: directoryStore.directoryURL,
                               organizeByDate: organizeByDate, effects: effectsStore.settings)
        }
    }

    private func handleTap(_ entry: PhotoGridEntry, file: CameraFile) {
        if case let .burst(group) = entry {
            toggleBurst(group.id)
            return
        }
        if tapToPreview {
            ZTransferHaptics.shared.longPress()
            openPreview(file, anchorFileID: file.id)
        } else {
            enqueueFileFromList(file)
        }
    }

    /// Android swaps the single-photo tap/hold actions when “tap to preview”
    /// is enabled. The burst collection keeps its dedicated contract: tap its
    /// arrow/action controls, hold the image area to preview the first member.
    private func handleLongPress(_ entry: PhotoGridEntry, file: CameraFile) {
        if case let .burst(group) = entry {
            ZTransferHaptics.shared.longPress()
            expandedBurstIDs.insert(group.id)
            openPreview(group.files[0], anchorFileID: file.id)
        } else if tapToPreview {
            enqueueFileFromList(file)
        } else {
            ZTransferHaptics.shared.longPress()
            openPreview(file, anchorFileID: file.id)
        }
    }

    private func enqueueFileFromList(_ file: CameraFile) {
        if directoryStore.directoryURL == nil {
            // Android routes a transfer attempt with no valid destination to the
            // existing settings overlay; it does not enqueue an unusable task.
            requestTransferDirectory()
        } else if !deferTransferStart {
            ZTransferHaptics.shared.tick()
            beginQueueFlightHold(1)
            startListQueueFlight(for: file)
            queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL,
                               organizeByDate: organizeByDate, effects: effectsStore.settings)
        } else {
            ZTransferHaptics.shared.tick()
            beginQueueFlightHold(1)
            startListQueueFlight(for: file)
            queueModel.enqueue(file, organizeByDate: organizeByDate, effects: effectsStore.settings)
        }
    }

    private func requestTransferDirectory() {
        transferDirectoryAttention = true
        showingSettings = true
        let hintID = UUID()
        remoteEntryHintID = hintID
        withAnimation(ZTransferMotion.standard) {
            remoteEntryHint = AppLocalized.resource("transfer_directory_required_hint")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, remoteEntryHintID == hintID else { return }
            withAnimation(ZTransferMotion.standard) { remoteEntryHint = nil }
        }
    }

    private func openPreview(_ file: CameraFile, anchorFileID: UInt32) {
        previewAnchor = cellBounds[anchorFileID]
        selectedFile = file
    }

    /// Measure both the ScrollView and the permanent top slot. Depending on the
    /// OS, `safeAreaInset` can report the ScrollView frame before or after its
    /// safe region is reduced; using the measured slot edge avoids subtracting
    /// its 36pt twice on either implementation.
    private var photoListVisibleViewport: CGRect {
        let measured = photoListViewportBounds
        let base = measured.width > 0 && measured.height > 0
            ? measured
            : UIScreen.main.bounds
        let measuredControls = photoListTopControlsBounds
        let top = measuredControls.width > 0 && measuredControls.height > 0
            ? max(base.minY, measuredControls.maxY)
            : base.minY + photoListTopControlsHeight
        let clampedTop = min(top, base.maxY)
        return CGRect(
            x: base.minX,
            y: clampedTop,
            width: base.width,
            height: max(0, base.maxY - clampedTop)
        )
    }

    @MainActor
    private func preparePreviewDismissTarget(_ file: CameraFile) async -> CGRect? {
        guard let targetSection = model.sections.first(where: { section in
            section.files.contains(where: { $0.id == file.id })
        }) else { return nil }
        guard !collapsedDays.contains(targetSection.day) else { return nil }

        if collapseBurstPhotos,
           let burstID = model.burstIDByFile[file.id],
           !expandedBurstIDs.contains(burstID) {
            expandedBurstIDs.insert(burstID)
            await Task.yield()
        }

        let viewport = photoListVisibleViewport
        let initialFrame = cellBounds[file.id]
        if let initialFrame,
           photoFrameIsFullyVisible(initialFrame, in: viewport) {
            return initialFrame
        }
        guard let reader = photoListScrollProxy else { return nil }

        let visibleEntries = model.sections.flatMap { section -> [(scrollID: String, fileID: UInt32)] in
            guard !collapsedDays.contains(section.day) else { return [] }
            return photoGridEntries(section.files, burstIDByFile: model.burstIDByFile,
                                    collapse: collapseBurstPhotos,
                                    expandedIDs: expandedBurstIDs).map { entry in
                (entry.id, entry.firstFile.id)
            }
        }
        guard let targetIndex = visibleEntries.firstIndex(where: { entry in
            entry.scrollID == "photo_\(file.id)"
        }) else { return nil }
        let visibleIndex = visibleEntries.firstIndex { entry in
            cellBounds[entry.fileID]?.intersects(viewport) == true
        } ?? targetIndex
        let runway = min(max(thumbnailColumns, 1), 4) * 3
        if abs(targetIndex - visibleIndex) > runway * 2 {
            let nearbyIndex = targetIndex > visibleIndex
                ? max(0, targetIndex - runway)
                : min(visibleEntries.count - 1, targetIndex + runway)
            reader.scrollTo(visibleEntries[nearbyIndex].scrollID, anchor: .center)
            await Task.yield()
        }
        let targetAnchor: UnitPoint
        if let initialFrame, initialFrame.minY < viewport.minY {
            targetAnchor = .top
        } else if let initialFrame, initialFrame.maxY > viewport.maxY {
            targetAnchor = .bottom
        } else if targetIndex < visibleIndex {
            targetAnchor = .top
        } else if targetIndex > visibleIndex {
            targetAnchor = .bottom
        } else {
            targetAnchor = .center
        }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) {
            reader.scrollTo("photo_\(file.id)", anchor: targetAnchor)
        }
        try? await Task.sleep(nanoseconds: 280_000_000)
        await Task.yield()
        guard let frame = cellBounds[file.id],
              photoFrameIsFullyVisible(frame, in: photoListVisibleViewport) else { return nil }
        return frame
    }

    @ViewBuilder
    private var queueFlightOverlay: some View {
        if !queueFlights.isEmpty {
            GeometryReader { proxy in
                ForEach(queueFlights) { flight in
                    PhotoListQueueFlightView(
                        flight: flight,
                        viewport: proxy.frame(in: .global),
                        target: flight.target
                    )
                    .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
    }

    private func startListQueueFlight(
        for file: CameraFile,
        count: Int = 1,
        from source: CGRect? = nil,
        packFiles: [CameraFile] = []
    ) {
        let screen = UIScreen.main.bounds
        let measuredSource = source ?? cellBounds[file.id]
        let from = measuredSource.map { frame in
            frame.isEmpty || frame.isInfinite || frame.isNull
                ? CGRect(x: screen.midX - 22, y: screen.midY - 22, width: 44, height: 44)
                : frame
        } ?? CGRect(x: screen.midX - 22, y: screen.midY - 22, width: 44, height: 44)
        let target = queueTargetBounds.isEmpty || queueTargetBounds.isInfinite || queueTargetBounds.isNull
            ? CGRect(x: screen.maxX - 13, y: 48, width: 1,
                     height: photoListTopControlsHeight)
            : queueTargetBounds
        let id = UUID()
        let flightCount = max(1, count)
        let visiblePackCandidates = count > 1 ? makeQueueFlightPacks(packFiles) : []
        let topImage = session.memoryThumbnailImage(file: file)
        let packDuration = visiblePackCandidates.isEmpty ? 0.0 : 0.42
        queueFlights.append(PhotoListQueueFlight(
            id: id,
            file: file,
            from: from,
            target: target,
            count: flightCount,
            startedAt: Date().addingTimeInterval(0.032),
            packDuration: packDuration,
            packs: visiblePackCandidates,
            image: topImage
        ))
        Task { @MainActor in
            // startedAt is immutable and 32 ms in the future. The live
            // TimelineView crosses that boundary by itself, so the animation
            // no longer depends on a second parent-state mutation being
            // delivered after insertion.
            try? await Task.sleep(nanoseconds: UInt64((0.032 + packDuration + 0.56) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finishQueueFlightHold(flightCount, caught: true)
            queueFlights.removeAll { $0.id == id }
        }
    }

    /// Freeze the number already visible before scheduling the real enqueue.
    /// The queue actor and the flight layer can now publish in either order
    /// without exposing the newly tapped task before the card reaches the pill.
    private func beginQueueFlightHold(_ count: Int) {
        let amount = max(0, count)
        guard amount > 0 else { return }
        if heldFlightCount == 0 { heldFlightBaselineRemaining = queueActualRemaining }
        heldFlightCount += amount
    }

    private func finishQueueFlightHold(_ count: Int, caught: Bool) {
        heldFlightCount = max(0, heldFlightCount - max(0, count))
        if heldFlightCount == 0 { heldFlightBaselineRemaining = nil }
        if caught { queueImpact &+= 1 }
    }

    private var queueActualRemaining: Int {
        let downloads = queueModel.snapshot.items.reduce(into: 0) { count, item in
            if item.status == .waiting || item.status == .transferring { count += 1 }
        }
        if downloads > 0 { return downloads }
        return queueModel.snapshot.items.reduce(into: 0) { count, item in
            if item.isGeneratingFrame { count += 1 }
        }
    }

    private func queueHiddenFlightCount(actualRemaining: Int) -> Int {
        guard heldFlightCount > 0, let baseline = heldFlightBaselineRemaining else { return 0 }
        return min(heldFlightCount, max(0, actualRemaining - baseline))
    }

    private func makeQueueFlightPacks(_ files: [CameraFile]) -> [PhotoListQueuePackSoul] {
        let screen = UIScreen.main.bounds
        var candidates: [PhotoListQueuePackSoul] = []
        for file in files {
            guard let bounds = cellBounds[file.id],
                  bounds.width > 0, bounds.height > 0,
                  bounds.intersects(screen) else { continue }
            candidates.append(PhotoListQueuePackSoul(
                bounds: bounds,
                image: session.memoryThumbnailImage(file: file)
            ))
        }
        candidates.sort {
            if $0.bounds.minY == $1.bounds.minY {
                return $0.bounds.minX < $1.bounds.minX
            }
            return $0.bounds.minY < $1.bounds.minY
        }
        guard candidates.count > 8 else { return candidates }
        return (0..<8).map { slot in
            let index = Int((Double(slot) * Double(candidates.count - 1) / 7.0).rounded())
            return candidates[index]
        }
    }

}

private struct PhotoListQueuePackSoul {
    let bounds: CGRect
    let image: UIImage?
}

private struct PhotoListQueueFlight: Identifiable {
    let id: UUID
    let file: CameraFile
    let from: CGRect
    let target: CGRect
    let count: Int
    let startedAt: Date
    let packDuration: TimeInterval
    let packs: [PhotoListQueuePackSoul]
    let image: UIImage?
}

private struct PhotoListQueueFlightView: View {
    let flight: PhotoListQueueFlight
    let viewport: CGRect
    let target: CGRect

    var body: some View {
        // Keep the short-lived timeline running from insertion. Its immutable
        // start time is 32 ms in the future, so the first two frames are the
        // transparent preroll and no follow-up state write is required.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(flight.startedAt)
            let packLinear = flight.packDuration > 0
                ? min(max(elapsed / flight.packDuration, 0), 1)
                : 1
            let linear = min(max((elapsed - flight.packDuration) / 0.56, 0), 1)
            let layers = flight.count > 1 ? min(flight.count, 3) : 1
            ZStack {
                ForEach(Array(flight.packs.enumerated()), id: \.offset) { index, soul in
                    PhotoListQueuePackSoulView(
                        soul: soul,
                        index: index,
                        count: flight.packs.count,
                        progress: CGFloat(packLinear),
                        destination: CGPoint(
                            x: flight.from.midX - viewport.minX,
                            y: flight.from.midY - viewport.minY
                        ),
                        viewport: viewport
                    )
                }
                ForEach(0..<layers, id: \.self) { layer in
                    Group {
                        if layer == layers - 1, let image = flight.image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            ZTransferColors.accentBlue.opacity(layer == layers - 1 ? 1 : 0.48)
                                .overlay {
                                    if layer == layers - 1 {
                                        Image(systemName: "photo").foregroundStyle(.white)
                                    }
                                }
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.8), lineWidth: 1))
                    .offset(
                        x: layers > 1 ? CGFloat(layer - 1) * 3 : 0,
                        y: layers > 1 ? CGFloat(1 - layer) * 2 : 0
                    )
                    .rotationEffect(.degrees(layers > 1 ? Double(layer - 1) * 9 : 0))
                }
            }
            .modifier(QueueFlightArc(
                progress: queueFlightEasedProgress(CGFloat(linear)),
                start: CGPoint(x: flight.from.midX - viewport.minX, y: flight.from.midY - viewport.minY),
                end: CGPoint(x: target.maxX - 28 - viewport.minX, y: target.midY - viewport.minY)
            ))
        }
    }
}

private struct PhotoListQueuePackSoulView: View {
    let soul: PhotoListQueuePackSoul
    let index: Int
    let count: Int
    let progress: CGFloat
    let destination: CGPoint
    let viewport: CGRect

    var body: some View {
        let step: CGFloat = count <= 1 ? 0 : 0.28 / CGFloat(count - 1)
        let span: CGFloat = count <= 1 ? 1 : 0.72
        let t = min(max((progress - CGFloat(index) * step) / span, 0), 1)
        let rise = min(t / 0.3, 1)
        let suckLinear = min(max((t - 0.3) / 0.7, 0), 1)
        let suck = suckLinear * suckLinear
        let start = CGPoint(
            x: soul.bounds.midX - viewport.minX,
            y: soul.bounds.midY - viewport.minY - 10 * rise
        )
        let point = CGPoint(
            x: start.x + (destination.x - start.x) * suck,
            y: start.y + (destination.y - start.y) * suck
        )
        let scale = (1 + 0.06 * rise) * (1 - 0.85 * suck)
        Group {
            if let image = soul.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZTransferColors.accentBlue.opacity(0.4)
            }
        }
        .frame(width: soul.bounds.width, height: soul.bounds.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .scaleEffect(scale)
        .opacity(t <= 0 || t >= 1 ? 0 : 0.75 * rise * (1 - 0.3 * suck))
        .position(point)
    }
}

/// Interpolate the path parameter, not the resulting endpoints. This recomputes
/// the Bezier position on each animation frame and never rotates the viewport.
@preconcurrency
private struct QueueFlightArc: AnimatableModifier {
    var progress: CGFloat
    let start: CGPoint
    let end: CGPoint

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = min(max(progress, 0), 1)
        let dx = abs(end.x - start.x)
        let lift = min(90, 36 + 0.35 * dx)
        let control = CGPoint(
            x: (start.x + end.x) / 2 - 52 * (1 - min(dx / 160, 1)),
            y: max(min(start.y, end.y) - lift, (48 - start.y - end.y) / 2)
        )
        let point = quadraticBezier(start: start, control: control, end: end, t: t)
        let appear = min(t / 0.12, 1)
        let scale = (0.7 + 0.3 * appear) * (1 - 0.62 * t)
        return content
            .scaleEffect(scale)
            .opacity(appear * (t > 0.94 ? (1 - t) / 0.06 : 1))
            .position(point)
    }
}

private func quadraticBezier(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
    let oneMinus = 1 - t
    return CGPoint(
        x: oneMinus * oneMinus * start.x + 2 * oneMinus * t * control.x + t * t * end.x,
        y: oneMinus * oneMinus * start.y + 2 * oneMinus * t * control.y + t * t * end.y
    )
}

/// Android QueueFlightEasing = CubicBezier(0.5, 0, 0.8, 0.35). Timeline-driven
/// flights solve x(t) explicitly so rendering does not depend on SwiftUI
/// committing an implicit animation transaction.
func queueFlightEasedProgress(_ linear: CGFloat) -> CGFloat {
    let x = min(max(linear, 0), 1)
    var lower: CGFloat = 0
    var upper: CGFloat = 1
    for _ in 0..<12 {
        let t = (lower + upper) / 2
        let remaining = 1 - t
        let sampleX = 3 * remaining * remaining * t * 0.5 +
            3 * remaining * t * t * 0.8 + t * t * t
        if sampleX < x { lower = t } else { upper = t }
    }
    let t = (lower + upper) / 2
    let remaining = 1 - t
    return 3 * remaining * t * t * 0.35 + t * t * t
}

private struct PhotoListCellBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [UInt32: CGRect] = [:]
    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct PhotoListSectionEnqueueBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct PhotoListQueueTargetPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// SignalPill family: USB keeps its dedicated mark, STA shows topology state,
/// and AP uses a static four-bar connected mark. iOS intentionally does not
/// request the restricted Access Wi-Fi Information capability.
struct PhotoListSignalIcon: View {
    let isUSB: Bool
    let wirelessMode: WirelessMode?
    var connected = true

    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.frostedGlass.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isUSB {
            ClassicUSBIcon(tint: ZTransferColors.accentBlue)
                .frame(width: 18, height: 18)
        } else if wirelessMode == .sta {
            let tint = connected ? ZTransferColors.accentBlue : ZTransferColors.statusError
            Canvas { context, size in
                let width = size.width * 0.16
                let gap = size.width * 0.10
                let heights: [CGFloat] = [0.30, 0.48, 0.66, 0.84].map { size.height * $0 }
                let total = width * 4 + gap * 3
                let start = (size.width - total) / 2
                for (index, height) in heights.enumerated() {
                    let x = start + CGFloat(index) * (width + gap)
                    let rect = CGRect(x: x, y: size.height - height, width: width, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: width * 0.35), with: .color(tint))
                }
            }
            .frame(width: 19, height: 18)
            .accessibilityLabel(AppLocalized.resource(connected ? "sta_signal_connected" : "sta_signal_disconnected_reconnect"))
        } else {
            if connected {
                let color = apConnectedBarColor
                HStack(alignment: .bottom, spacing: 2.5) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(color)
                            .frame(width: 4, height: CGFloat(6 + index * 3))
                    }
                }
                // Android SignalPill uses four exact 4dp bars with 2.5dp
                // gaps. The former proportional Canvas produced fractional
                // widths at different sub-pixel origins, so equally specified
                // bars rasterized at visibly different widths on Retina.
                .frame(width: 23.5, height: 15, alignment: .bottom)
                .accessibilityLabel(AppLocalized.resource("camera_session_notification_title"))
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ZTransferColors.statusError)
                    .accessibilityLabel(AppLocalized.resource("camera_not_connected"))
            }
        }
    }

    private var apConnectedBarColor: Color {
        let skin = ZTransferButtonSkin(storedValue: skinPreset)
        let dark = colorScheme == .dark
        if skin == .wood {
            if dark {
                return Color(red: 0.659, green: 0.906, blue: 0.737)
            } else {
                return Color(red: 0.086, green: 0.310, blue: 0.196)
            }
        }
        return ZTransferColors.accentBlue
    }
}

/// Android's hand-drawn funnel mark, kept as a line icon instead of the
/// circular SF Symbols variant so the compact top buttons share one visual
/// language across platforms.
struct PhotoListFilterIcon: View {
    let active: Bool
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let path = Path { path in
                path.move(to: CGPoint(x: 0.12 * s, y: 0.18 * s))
                path.addLine(to: CGPoint(x: 0.88 * s, y: 0.18 * s))
                path.addLine(to: CGPoint(x: 0.60 * s, y: 0.51 * s))
                path.addLine(to: CGPoint(x: 0.60 * s, y: 0.76 * s))
                path.addLine(to: CGPoint(x: 0.40 * s, y: 0.86 * s))
                path.addLine(to: CGPoint(x: 0.40 * s, y: 0.51 * s))
                path.closeSubpath()
            }
            if active {
                context.fill(path, with: .color(color))
            } else {
                context.stroke(path, with: .color(color), style: StrokeStyle(
                    lineWidth: 2.1,
                    lineCap: .round,
                    lineJoin: .round
                ))
            }
        }
        .accessibilityLabel(AppLocalized.resource("cd_filter_type"))
    }
}

/// Android's compact checklist entry mark: two rounded checks paired with
/// short rules. It stays legible at the same 20pt mark used by the signal icon.
private struct PhotoListQueueIcon: View {
    var tint: Color = ZTransferColors.statusConnected

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: max(1.8, size.width * 0.11), lineCap: .round, lineJoin: .round)
            let rowGap = size.height * 0.46
            for row in 0..<2 {
                let y = size.height * 0.28 + CGFloat(row) * rowGap
                var check = Path()
                check.move(to: CGPoint(x: size.width * 0.06, y: y))
                check.addLine(to: CGPoint(x: size.width * 0.22, y: y + size.height * 0.16))
                check.addLine(to: CGPoint(x: size.width * 0.42, y: y - size.height * 0.13))
                context.stroke(check, with: .color(tint), style: stroke)

                var rule = Path()
                rule.move(to: CGPoint(x: size.width * 0.58, y: y - size.height * 0.01))
                rule.addLine(to: CGPoint(x: size.width * 0.94, y: y - size.height * 0.01))
                context.stroke(rule, with: .color(tint), style: stroke)
            }
        }
        .accessibilityLabel(AppLocalized.resource("cd_transfer"))
    }
}

private func formatDateHeader(_ raw: String) -> String {
    guard raw.count == 8,
          raw.allSatisfy(\.isNumber) else { return raw }
    let chars = Array(raw)
    return "\(chars[0])\(chars[1])\(chars[2])\(chars[3])-\(chars[4])\(chars[5])-\(chars[6])\(chars[7])"
}

private struct PhotoListEmptyState: View {
    let filterActive: Bool
    let usb: Bool
    let onClearFilter: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                let alpha = 0.35 + 0.25 * ((sin(phase * 2 * .pi) + 1) / 2)
                Image(systemName: filterActive ? "line.3.horizontal.decrease.circle" : "folder")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(ZTransferColors.secondaryText.opacity(alpha))
            }
            Text(AppLocalized.resource(filterActive ? "no_photos_match_filter" : "no_photos_on_camera"))
                .zTransferText(size: ZTransferMetrics.body)
                .foregroundStyle(ZTransferColors.secondaryText)
            if !filterActive && usb {
                Text(AppLocalized.resource("usb_turn_on_camera_hint"))
                    .zTransferText(size: ZTransferMetrics.caption)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            if filterActive {
                Button(action: onClearFilter) {
                    Text(AppLocalized.resource("clear_filters"))
                        .foregroundStyle(ZTransferColors.primaryText)
                }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 18))
            }
        }
    }
}

/// Android keeps an established USB workspace mounted after cable/power loss.
/// When no catalog was ever loaded, show the wired recovery guidance instead
/// of an endless spinner or a generic protocol error. There is intentionally
/// no disconnect/reconnect action: recovery remains physical reattach/power-on.
private struct PhotoListUSBDisconnectedState: View {
    var body: some View {
        VStack(spacing: 0) {
            ClassicUSBIcon(tint: ZTransferColors.accentOrange)
                .frame(width: 64, height: 64)
            Spacer().frame(height: 16)
            Text(AppLocalized.resource("usb_connection_lost"))
                .zTransferTypography(.titleMedium, weight: .medium)
                .foregroundStyle(ZTransferColors.primaryText)
            Spacer().frame(height: 6)
            Text(AppLocalized.resource("reconnect_camera_usb"))
                .zTransferTypography(.bodySmall)
                .foregroundStyle(ZTransferColors.secondaryText)
                .multilineTextAlignment(.center)
        }
    }
}

private struct PhotoListScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum PhotoGridEntry: Identifiable {
    case photo(CameraFile)
    case burst(BurstPhotoGroup)
    var id: String {
        switch self { case let .photo(file): return "photo_\(file.id)"; case let .burst(group): return "burst_\(group.id)" }
    }
    var firstFile: CameraFile {
        switch self { case let .photo(file): return file; case let .burst(group): return group.files[0] }
    }
    var isPhoto: Bool {
        if case .photo = self { return true }
        return false
    }
}

private func photoGridEntries(_ files: [CameraFile], burstIDByFile: [UInt32: String], collapse: Bool = true,
                              expandedIDs: Set<String> = []) -> [PhotoGridEntry] {
    guard collapse else { return files.map(PhotoGridEntry.photo) }
    let visibleGroups = Dictionary(grouping: files.compactMap { file -> (String, CameraFile)? in
        burstIDByFile[file.id].map { ($0, file) }
    }, by: \.0).mapValues { $0.map(\.1) }
    var entries: [PhotoGridEntry] = []
    var collected = Set<String>()
    for file in files {
        guard let id = burstIDByFile[file.id], let members = visibleGroups[id], members.count >= 2 else {
            entries.append(.photo(file)); continue
        }
        if collected.insert(id).inserted {
            entries.append(.burst(BurstPhotoGroup(id: id, files: members)))
            if expandedIDs.contains(id) { entries.append(contentsOf: members.map(PhotoGridEntry.photo)) }
        }
    }
    return entries
}

private enum QueuePillVisualMode: Hashable, CaseIterable {
    case icon, done, paused, generating, counting
}

private struct LiveQueuePill: View {
    let snapshot: TransferQueueSnapshot
    @ObservedObject var progressModel: TransferQueueProgressViewModel
    let heldCount: Int
    let heldBaselineRemaining: Int?

    var body: some View {
        QueuePill(
            snapshot: snapshot,
            activeProgress: progressModel.activeProgress,
            heldCount: heldCount,
            heldBaselineRemaining: heldBaselineRemaining
        )
    }
}

struct QueuePill: View {
    let snapshot: TransferQueueSnapshot
    let activeProgress: TransferActiveProgress?
    let heldCount: Int
    let heldBaselineRemaining: Int?

    @State private var showDoneLabel = false
    @State private var sawActiveBatch = false
    @State private var previousAllDone: Bool?
    @State private var countingVisible = false
    @State private var finishProgressVisible = false
    @State private var retainedProgressSeed = "queue"
    @State private var doneTask: Task<Void, Never>?
    @State private var measuredWidths: [QueuePillVisualMode: CGFloat] = [:]
    @State private var renderedWidth: CGFloat = 40
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.frostedGlass.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var usesNativeLiquidGlass: Bool {
        ZTransferButtonSkin(storedValue: skinPreset) == .liquidGlass
    }

    private var downloadRemaining: Int {
        snapshot.items.reduce(into: 0) { count, item in
            if item.status == .waiting || item.status == .transferring { count += 1 }
        }
    }

    private var generationCount: Int {
        snapshot.items.reduce(into: 0) { count, item in
            if item.isGeneratingFrame { count += 1 }
        }
    }

    private var activeItem: TransferQueueItem? {
        snapshot.items.first(where: { $0.status == .transferring })
    }

    private var progressOwner: TransferQueueItem? {
        activeItem
            ?? snapshot.items.first(where: { $0.isGeneratingFrame })
            ?? snapshot.items.first(where: { $0.status == .waiting })
    }

    private var activeSpeed: Int64 {
        guard snapshot.isTransferring else { return 0 }
        return activeProgress?.retainedBytesPerSecond ?? activeItem?.bytesPerSecond ?? 0
    }

    private var activeSpeedText: String? {
        activeSpeed > 0 ? speedText(activeSpeed) : nil
    }

    private var displayRemainingCount: Int {
        max(0, actualRemainingCount - hiddenFlightCount)
    }

    private var actualRemainingCount: Int {
        downloadRemaining > 0 ? downloadRemaining : generationCount
    }

    private var hiddenFlightCount: Int {
        guard heldCount > 0, let baseline = heldBaselineRemaining else { return 0 }
        return min(heldCount, max(0, actualRemainingCount - baseline))
    }

    private var rawAllDone: Bool { downloadRemaining == 0 && generationCount == 0 }
    private var allDone: Bool { rawAllDone && heldCount == 0 }
    private var paused: Bool { !snapshot.isTransferring && downloadRemaining > 0 }
    private var hasCancelled: Bool { snapshot.items.contains { $0.status == .cancelled } }
    private var hasWorkingTask: Bool { activeItem != nil || generationCount > 0 }
    private var completionPending: Bool {
        allDone && previousAllDone == false && !hasCancelled
    }
    private var doneVisible: Bool { showDoneLabel || completionPending }
    private var completionFillVisible: Bool {
        finishProgressVisible || (completionPending && sawActiveBatch)
    }
    private var allRemainingTasksAreInFlight: Bool {
        heldCount > 0 && displayRemainingCount == 0
    }
    private var collapsedToIcon: Bool {
        allRemainingTasksAreInFlight ||
            (!paused && ((allDone && !doneVisible) || (!allDone && !countingVisible)))
    }
    private var visualMode: QueuePillVisualMode {
        if collapsedToIcon { return .icon }
        if doneVisible { return .done }
        if paused { return .paused }
        if downloadRemaining == 0, generationCount > 0 { return .generating }
        return .counting
    }
    private var progressFraction: Double {
        if completionFillVisible { return 1 }
        if let activeItem {
            return activeProgress?.taskID == activeItem.id
                ? activeProgress!.fraction
                : activeItem.progress
        }
        return generationCount > 0 ? 1 : 0
    }
    private var targetWidth: CGFloat {
        guard visualMode != .icon else { return 40 }
        // Hold the previous measured width for the one layout pass needed to
        // measure new content. This prevents text appearing outside a width
        // that is still springing from the icon state.
        return max(40, measuredWidths[visualMode] ?? measuredWidths.values.max() ?? 40)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if visualMode == .icon || usesNativeLiquidGlass {
                ZTransferButtonMaterialSurface(
                    skin: .init(storedValue: skinPreset),
                    cornerRadius: 22
                )
            } else {
                // Android speed/count/generating/Done/paused capsule is a
                // status surface and intentionally ignores button themes.
                ZTransferGlassSurface(cornerRadius: 22, kind: .button)
            }

            // Done is a terminal confirmation label, not another progress
            // phase. Never carry the completed liquid fill underneath it.
            if visualMode != .done && (!allDone || completionFillVisible) {
                LiquidTransferProgressFill(
                    progress: progressFraction,
                    seed: progressOwner?.id.uuidString ?? retainedProgressSeed,
                    isCapsule: true,
                    waveEligible: activeItem != nil || completionFillVisible
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(Capsule())
            }

            // Keep every content phase inside one fixed clipping viewport.
            // Persistent layers avoid SwiftUI re-parenting the outgoing label
            // while the capsule width changes (the old Done label previously
            // appeared to travel past the right edge during collapse).
            ZStack(alignment: .trailing) {
                ForEach(QueuePillVisualMode.allCases, id: \.self) { mode in
                    pillContent(for: mode)
                        .padding(.horizontal, mode == .icon ? 0 : 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .trailing)
                        .opacity(mode == visualMode ? 1 : 0)
                        .accessibilityHidden(mode != visualMode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: visualMode)
        }
        .frame(width: renderedWidth, height: photoListTopControlsHeight, alignment: .trailing)
        .compositingGroup()
        .clipShape(Capsule())
        .background {
            measurementContent(for: visualMode)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, visualMode == .icon ? 0 : 16)
                .hidden()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: QueuePillMeasuredWidthPreferenceKey.self,
                            value: [visualMode: proxy.size.width]
                        )
                    }
                }
        }
        .onPreferenceChange(QueuePillMeasuredWidthPreferenceKey.self) { widths in
            for (mode, width) in widths where width > 0 {
                if abs((measuredWidths[mode] ?? 0) - width) > 0.5 {
                    measuredWidths[mode] = width
                }
            }
        }
        .overlay {
            if !usesNativeLiquidGlass {
                Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
            }
        }
        .onChange(of: targetWidth) { width in
            // Change only the rendered width. Updating it in a dedicated
            // transaction prevents the content swap from inheriting the
            // spring and being translated by SwiftUI's parent layout.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                renderedWidth = width
            }
        }
        .task(id: "\(hasWorkingTask)-\(paused)-\(displayRemainingCount)-\(allDone)") {
            if paused || hasWorkingTask {
                countingVisible = true
            } else if displayRemainingCount > 0 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                countingVisible = true
            } else {
                countingVisible = false
            }
        }
        .onChange(of: progressOwner?.id) { _ in
            if let id = progressOwner?.id { retainedProgressSeed = id.uuidString }
        }
        .onChange(of: hasWorkingTask) { active in
            guard active else { return }
            sawActiveBatch = true
            doneTask?.cancel()
            finishProgressVisible = false
            showDoneLabel = false
        }
        .onChange(of: allDone) { done in
            guard let previousAllDone else {
                self.previousAllDone = done
                return
            }
            if done && !previousAllDone {
                let celebrate = !hasCancelled && sawActiveBatch
                if !hasCancelled {
                    finishProgressVisible = celebrate
                    showDoneLabel = true
                    if celebrate { ZTransferHaptics.shared.success() }
                    doneTask?.cancel()
                    doneTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        guard !Task.isCancelled else { return }
                        showDoneLabel = false
                        finishProgressVisible = false
                    }
                }
                sawActiveBatch = false
            }
            self.previousAllDone = done
        }
        .onAppear {
            previousAllDone = allDone
            sawActiveBatch = hasWorkingTask
            renderedWidth = targetWidth
            if let id = progressOwner?.id { retainedProgressSeed = id.uuidString }
        }
        .onDisappear { doneTask?.cancel() }
    }

    @ViewBuilder
    private func pillContent(for mode: QueuePillVisualMode) -> some View {
        switch mode {
        case .icon:
            PhotoListQueueIcon(tint: zTransferMaterialContentColor(
                skin: .init(storedValue: skinPreset),
                scheme: colorScheme,
                fallback: ZTransferColors.statusConnected
            ))
                // The custom canvas occupies more of its viewport than
                // Android's 22dp Material Checklist path. A 20pt viewport
                // yields the same visible 17–18pt mark inside the 40pt pill.
                .frame(width: 20, height: 20)
                .frame(width: 40, height: photoListTopControlsHeight)
        case .done:
            Text("Done")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ZTransferColors.statusConnected)
                .lineLimit(1)
        case .paused:
            QueuePillRollingCount(count: displayRemainingCount)
        case .generating:
            HStack(alignment: .center, spacing: 6) {
                Text(AppLocalized.resource("queue_pill_generating"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ZTransferColors.accentBlue)
                    .lineLimit(1)
                QueuePillRollingCount(count: generationCount)
            }
        case .counting:
            HStack(alignment: .center, spacing: 8) {
                if let activeSpeedText {
                    Text(activeSpeedText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ZTransferColors.accentBlue)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                QueuePillRollingCount(count: displayRemainingCount)
            }
        }
    }

    @ViewBuilder
    private func measurementContent(for mode: QueuePillVisualMode) -> some View {
        switch mode {
        case .icon:
            Color.clear.frame(width: 40, height: photoListTopControlsHeight)
        case .done:
            Text("Done").font(.system(size: 14, weight: .bold)).lineLimit(1)
        case .paused:
            measurementCount(displayRemainingCount)
        case .generating:
            HStack(spacing: 6) {
                Text(AppLocalized.resource("queue_pill_generating"))
                    .font(.system(size: 14, weight: .bold)).lineLimit(1)
                measurementCount(generationCount)
            }
        case .counting:
            HStack(spacing: activeSpeedText == nil ? 0 : 8) {
                if let activeSpeedText {
                    Text(activeSpeedText)
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit().lineLimit(1)
                }
                measurementCount(displayRemainingCount)
            }
        }
    }

    private func measurementCount(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 14, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
    }

    private func speedText(_ bytesPerSecond: Int64) -> String {
        switch bytesPerSecond {
        case ..<1024: return "\(bytesPerSecond) B/s"
        case ..<(1024 * 1024): return String(format: "%.1f KB/s", Double(bytesPerSecond) / 1024)
        default: return String(format: "%.1f MB/s", Double(bytesPerSecond) / (1024 * 1024))
        }
    }
}

private struct QueuePillMeasuredWidthPreferenceKey: PreferenceKey {
    static let defaultValue: [QueuePillVisualMode: CGFloat] = [:]
    static func reduce(
        value: inout [QueuePillVisualMode: CGFloat],
        nextValue: () -> [QueuePillVisualMode: CGFloat]
    ) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct QueuePillRollingCount: View {
    let count: Int
    @State private var current: Int
    @State private var outgoing: Int?
    @State private var direction: CGFloat = 1
    @State private var progress: CGFloat = 1
    @State private var animationTask: Task<Void, Never>?

    init(count: Int) {
        self.count = count
        _current = State(initialValue: count)
    }

    var body: some View {
        ZStack {
            if let outgoing {
                countText(outgoing)
                    .offset(y: -10 * direction * progress)
                    .opacity(1 - progress)
            }
            countText(current)
                .offset(y: 10 * direction * (1 - progress))
                .opacity(progress)
        }
        .frame(height: 20)
        .clipped()
        .fixedSize(horizontal: true, vertical: false)
        .onChange(of: count) { value in
            guard value != current else { return }
            animationTask?.cancel()
            direction = value < current ? 1 : -1
            outgoing = current
            current = value
            progress = 0
            animationTask = Task { @MainActor in
                // Mount both number layers before advancing the odometer.
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) { progress = 1 }
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }
                outgoing = nil
                animationTask = nil
            }
        }
        .onDisappear { animationTask?.cancel() }
    }

    private func countText(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(ZTransferColors.primaryText)
            .monospacedDigit()
            .lineLimit(1)
    }
}

private struct QueuePillButtonStyle: ButtonStyle {
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.frostedGlass.rawValue

    func makeBody(configuration: Configuration) -> some View {
        let nativeGlass = ZTransferButtonSkin(storedValue: skinPreset) == .liquidGlass
        configuration.label
            .scaleEffect(configuration.isPressed && !nativeGlass ? 0.95 : 1, anchor: .trailing)
            .animation(configuration.isPressed
                       ? .easeOut(duration: 0.08)
                       : .spring(response: 0.34, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}

private struct QueueControlsCatchEffect: ViewModifier {
    let trigger: Int
    @State private var scale: CGFloat = 1
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .trailing)
            .onChange(of: trigger) { value in
                guard value > 0 else { return }
                task?.cancel()
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.11)) {
                    scale = 1.18
                }
                task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    guard !Task.isCancelled else { return }
                    // Compose Motion.bouncy(): stiffness 200, damping ratio
                    // 0.5. Use the equivalent physical SwiftUI spring rather
                    // than an approximate response/damping pair.
                    withAnimation(.interpolatingSpring(
                        mass: 1,
                        stiffness: 200,
                        damping: 2 * 0.5 * sqrt(200)
                    )) {
                        scale = 1
                    }
                }
            }
            .onDisappear { task?.cancel() }
    }
}

private struct LiveTransferStatusBadge: View {
    let task: TransferQueueItem
    @ObservedObject var progressModel: TransferQueueProgressViewModel

    var body: some View {
        let progress = progressModel.activeProgress
        TransferStatusBadge(
            status: task.status,
            progress: progress.flatMap { $0.taskID == task.id ? $0.fraction : nil } ?? task.progress,
            taskID: task.id
        )
    }
}

private struct CameraThumbnailView: View {
    let session: CameraSession
    var file: CameraFile?
    var allowRemoteThumbnail = true
    var transferred: Bool = false
    var inBurst: Bool = false
    var showsCornerBadges: Bool = true
    var queueTask: TransferQueueItem? = nil
    var progressModel: TransferQueueProgressViewModel? = nil
    @State private var image: UIImage?

    init(
        session: CameraSession,
        file: CameraFile? = nil,
        allowRemoteThumbnail: Bool = true,
        transferred: Bool = false,
        inBurst: Bool = false,
        showsCornerBadges: Bool = true,
        queueTask: TransferQueueItem? = nil,
        progressModel: TransferQueueProgressViewModel? = nil
    ) {
        self.session = session
        self.file = file
        self.allowRemoteThumbnail = allowRemoteThumbnail
        self.transferred = transferred
        self.inBurst = inBurst
        self.showsCornerBadges = showsCornerBadges
        self.queueTask = queueTask
        self.progressModel = progressModel
        _image = State(initialValue: file.flatMap { session.memoryThumbnailImage(file: $0) })
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else {
                    // Android uses a stable media-type placeholder both while
                    // loading and after a missing thumbnail. A failed bounded
                    // RAW probe must never look like an operation still running.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.08))
                        .overlay {
                            Image(systemName: file.map {
                                [".mov", ".mp4"].contains($0.fileExtension) ? "film" : "photo"
                            } ?? "photo")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                        }
                }
            }
            if let file, showsCornerBadges {
                if !file.fileExtension.isEmpty {
                    Text(file.fileExtension.dropFirst().uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(extensionColor(file.fileExtension), in: UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 6)))
                }
                if inBurst {
                    BurstGlyph(size: 13)
                        .frame(width: 23, height: 13)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.teal.opacity(0.85), in: UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if file.isProtected {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(4)
                        .background(Color.yellow.opacity(0.9), in: UnevenRoundedRectangle(cornerRadii: .init(topTrailing: 6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                if let task = queueTask, task.status != .completed {
                    Color.black.opacity(0.35).frame(width: geometry.size.width, height: geometry.size.height)
                    Group {
                        if let progressModel {
                            LiveTransferStatusBadge(task: task, progressModel: progressModel)
                        } else {
                            TransferStatusBadge(status: task.status, progress: task.progress, taskID: task.id)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(4)
                } else if transferred {
                    TransferredPhotoBadge()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(4)
                }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, minHeight: 0)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: allowRemoteThumbnail) {
            guard let file else { return }
            if session.wirelessMode == .sta {
                // View lifetime owns only observation. The session's ordered
                // pipeline keeps loading even when this cell leaves the grid.
                for await _ in await session.thumbnailUpdates(handle: file.id) {
                    guard !Task.isCancelled else { return }
                    if let cached = try? await session.thumbnailImage(file: file, allowRemote: false) {
                        image = cached
                        return
                    }
                }
            } else if image == nil,
                      let image = try? await session.thumbnailImage(file: file, allowRemote: allowRemoteThumbnail) {
                self.image = image
            }
        }
    }

    private func extensionColor(_ ext: String) -> Color {
        switch ext.lowercased() {
        case ".jpg": return ZTransferColors.accentBlue.opacity(0.85)
        case ".nef": return Color.purple.opacity(0.85)
        case ".mov", ".mp4": return ZTransferColors.accentOrange.opacity(0.85)
        default: return Color.gray.opacity(0.85)
        }
    }
}

private struct BurstThumbnailView: View {
    let session: CameraSession
    let group: BurstPhotoGroup
    var allowRemoteThumbnails = true
    var transferred: Bool = false
    var expanded = false
    var onExpand: () -> Void = {}
    var onEnqueue: () -> Void = {}
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let cardSide = side * 0.86
            ZStack {
                ForEach(Array(group.files.prefix(3).enumerated().reversed()), id: \.element.id) { item in
                    CameraThumbnailView(session: session, file: item.element,
                                        allowRemoteThumbnail: allowRemoteThumbnails,
                                        showsCornerBadges: false)
                        .frame(width: cardSide, height: cardSide)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .rotationEffect(.degrees(item.offset == 0 ? 0 : item.offset == 1 ? -5 : 5))
                        .offset(x: item.offset == 0 ? 0 : item.offset == 1 ? -side * 0.025 : side * 0.025,
                                y: item.offset == 0 ? 0 : side * 0.02)
                }
                VStack {
                    HStack {
                        HStack(spacing: 4) {
                            BurstGlyph(size: 13).frame(width: 23, height: 13)
                            Text("\(group.files.count)")
                        }.font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.teal.opacity(0.9), in: Capsule())
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        burstButton("plus", size: side * 0.32, action: onEnqueue)
                        Spacer(minLength: 0)
                        burstArrowButton(size: side * 0.32, expanded: expanded, action: onExpand)
                    }
                }.frame(width: cardSide, height: cardSide)
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.aspectRatio(1, contentMode: .fit)
    }

    private func burstButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(ZTransferColors.accentBlue)
                .frame(width: size, height: size)
        }.buttonStyle(ZTransferGlassButtonStyle(cornerRadius: size / 2))
    }

    private func extensionColor(_ ext: String) -> Color {
        ext.lowercased() == ".nef" ? Color.purple.opacity(0.9) : ZTransferColors.accentBlue.opacity(0.9)
    }

    private func burstArrowButton(size: CGFloat, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(expanded ? 180 : 0))
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(ZTransferColors.accentBlue)
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.24), value: expanded)
        }.buttonStyle(ZTransferGlassButtonStyle(cornerRadius: size / 2))
    }

}

/// Shared burst marker matching Android: stacked frames with motion trails.
struct BurstGlyph: View {
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: size * 0.18) {
            GeometryReader { proxy in
                Path { p in
                    let unit = proxy.size.width / 24
                    for x in [1.0, 5.0] { p.addRect(CGRect(x: x * unit, y: 3 * unit, width: 2 * unit, height: 18 * unit)) }
                    p.addRect(CGRect(x: 9 * unit, y: 3 * unit, width: 14 * unit, height: 18 * unit))
                    p.move(to: CGPoint(x: 10 * unit, y: 19 * unit))
                    p.addLine(to: CGPoint(x: 14 * unit, y: 13 * unit))
                    p.addLine(to: CGPoint(x: 17 * unit, y: 17 * unit))
                    p.addLine(to: CGPoint(x: 19 * unit, y: 14 * unit))
                    p.addLine(to: CGPoint(x: 22 * unit, y: 19 * unit))
                    p.closeSubpath()
                }.fill(style: FillStyle(eoFill: true))
            }.frame(width: size, height: size)
            VStack(alignment: .leading, spacing: size * 0.11) {
                ForEach([0.64, 0.45, 0.27], id: \.self) { ratio in
                    Capsule().frame(width: size * ratio, height: size * 0.09)
                }
            }
        }
    }
}

struct TransferStatusBadge: View {
    let status: TransferStatus
    var progress: Double = 0
    var taskID: UUID?
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45))
            if status == .transferring {
                SmoothTransferProgress(target: progress, resetKey: taskID) { value in
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: value)
                            .stroke(ZTransferColors.accentBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.frame(width: 15, height: 15)
                }
            } else {
                Image(systemName: status == .completed ? "checkmark" : status == .waiting ? "clock" : status == .failed ? "exclamationmark" : "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status == .completed ? ZTransferColors.statusConnected : status == .failed ? ZTransferColors.statusError : status == .waiting ? ZTransferColors.accentYellow : ZTransferColors.secondaryText)
            }
        }.frame(width: 22, height: 22)
        .animation(.linear(duration: 0.2), value: status)
    }
}

struct TransferredPhotoBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ZTransferColors.statusConnected)
            .frame(width: 24, height: 24)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(ZTransferColors.statusConnected.opacity(0.72), lineWidth: 1))
    }
}
