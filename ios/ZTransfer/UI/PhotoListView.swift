import SwiftUI
import UIKit

func normalizedThumbnailColumns(_ value: Int) -> Int {
    min(max(value, 2), 4)
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

/// Android's grid uses the system long-press detector. The user requested a
/// faster iOS preview on 2026-10-19: 250 → 200ms, for both single/burst images.
/// Keep the 12pt movement cancellation and the separate transfer threshold.
let photoPreviewLongPressDuration = 0.20
private let photoTransferLongPressDuration = 0.25

/// FileListScreen's combinedClickable resolves a hold before its release tap.
/// Separate onTapGesture/onLongPressGesture modifiers let SwiftUI wait for the
/// tap to fail (~750ms in actual touch tests), regardless of the hold threshold.
/// One exclusive gesture starts the hold timer immediately; moving >12pt still
/// fails it so the enclosing ScrollView can pan. Burst buttons own their input.
private struct PhotoCellInput: ViewModifier {
    var enabled: Bool
    var duration: Double
    var feedbackForTransfer: Bool
    var onTap: () -> Void
    var onHold: () -> Void
    @State private var haptics = ZTransferHaptics()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                LongPressGesture(minimumDuration: duration, maximumDistance: 12)
                    .exclusively(before: TapGesture())
                    .onEnded { value in
                        switch value {
                        case .first(true):
                            // The accepted enqueue owns the one confirmation.
                            // Stop anticipation without changing gesture recognition.
                            haptics.cancelProgressiveHold()
                            onHold()
                        case .second: onTap()
                        default: break
                        }
                    }
            )
            .background {
                if feedbackForTransfer {
                    ZTransferHoldTouchObservation(haptics: haptics,
                        durationMilliseconds: Int(duration * 1_000), maximumMovement: 12)
                }
            }
            .onChange(of: feedbackForTransfer) { _ in haptics.cancelProgressiveHold() }
            .onChange(of: scenePhase) { if $0 != .active { haptics.cancelProgressiveHold() } }
            .onDisappear { haptics.cancelProgressiveHold() }
        } else {
            content
        }
    }
}

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

struct PhotoCellReveal: ViewModifier {
    let active: Bool
    let trigger: Int
    let delay: UInt64
    @State private var progress: CGFloat = 1
    @State private var startedTrigger: Int?

    func body(content: Content) -> some View {
        // Android initializes revealProgress at zero before composing the cell.
        // A task runs after SwiftUI's first body: resetting from one inside it
        // showed a fully visible frame before the entrance could begin.
        let visibleProgress = active ? (startedTrigger == trigger ? progress : 0) : 1
        content
            .opacity(visibleProgress)
            .scaleEffect(0.94 + 0.06 * visibleProgress)
            .task(id: "\(trigger)|\(active)") {
                guard active else { startedTrigger = nil; progress = 1; return }
                let transaction = Transaction(animation: nil)
                withTransaction(transaction) { startedTrigger = trigger; progress = 0 }
                do {
                    // Especially for the first cell (zero stagger), a Task yield
                    // can merge both endpoints into one transaction and flash in.
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    else { try await ZTransferNextDisplayFrame.wait() }
                    try Task.checkCancellation()
                } catch { return }
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)) { progress = 1 }
            }
    }
}

/// Android collapseHeight belongs to each cell, including its bottom gap.
/// Rows move together as their actual heights shrink; clipping a whole grid
/// only hides stationary rows and leaves a discontinuity at disposal.
struct PhotoDateCellCollapseLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.init(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: .init(width: bounds.width, height: nil))
    }
}

struct PhotoDateCellCollapse: ViewModifier {
    var progress: CGFloat
    func body(content: Content) -> some View {
        PhotoDateCellCollapseLayout(progress: progress) {
            content.padding(.bottom, 6)
        }
        .opacity(min(1, max(0, progress)))
        .clipped()
    }
}

private struct PhotoListViewportPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

private struct PhotoListScrollItemsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct PhotoListScrollLayout: Equatable {
    let sections: [PhotoDaySection]
    let burstIDs: [UInt32: String]
    let collapseBursts: Bool
    let expandedBursts: Set<String>
    let collapsedDays: Set<String>
    let collapsingDay: String?
    let keepCount: Int

    func indices(entriesByDay: [String: [PhotoGridEntry]]? = nil) -> [String: Int] {
        var result: [String: Int] = [:]
        var index = 0
        for section in sections {
            result["header_\(section.day)"] = index
            index += 1
            guard !collapsedDays.contains(section.day) || collapsingDay == section.day else { continue }
            let entries = entriesByDay?[section.day] ?? photoGridEntries(section.files, burstIDByFile: burstIDs,
                                           collapse: collapseBursts, expandedIDs: expandedBursts)
            let count = collapsingDay == section.day ? min(keepCount, entries.count) : entries.count
            for entry in entries.prefix(count) {
                result[entry.id] = index
                index += 1
            }
        }
        return result
    }
}

/// Grid cells and scroll indices share one catalog/configuration projection.
/// Geometry, transfer animation frames and popup state reuse these arrays.
final class PhotoListGridCache {
    struct Snapshot {
        let entriesByDay: [String: [PhotoGridEntry]]
        let indices: [String: Int]
    }
    private var input: PhotoListScrollLayout?
    private var value = Snapshot(entriesByDay: [:], indices: [:])
    #if DEBUG
    private(set) var buildCount = 0
    #endif
    func snapshot(for layout: PhotoListScrollLayout) -> Snapshot {
        guard input != layout else { return value }
        let entries = Dictionary(uniqueKeysWithValues: layout.sections.map { section in
            (section.day, photoGridEntries(section.files, burstIDByFile: layout.burstIDs,
                                          collapse: layout.collapseBursts, expandedIDs: layout.expandedBursts))
        })
        value = Snapshot(entriesByDay: entries, indices: layout.indices(entriesByDay: entries))
        input = layout
        #if DEBUG
        buildCount += 1
        #endif
        return value
    }
}

private struct PhotoListTopControlsBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

// Android FileListScreen: all compact top controls are 40 x 36dp.
let photoListTopControlsHeight: CGFloat = 36
let photoListCompactButtonWidth: CGFloat = 40

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

private struct PhotoListSessionTaskID: Equatable {
    let session: ObjectIdentifier?
    let value: Bool
}

@MainActor struct PhotoListView: View {
    @ObservedObject private var model: PhotoListViewModel
    @StateObject private var queueModel: TransferQueueViewModel
    @ObservedObject private var directoryStore: DirectoryAccessStore
    let effectsStore: PhotoEffectsStore
    let isSessionConnected: Bool
    let onRetrySTA: () -> Void
    let onTransportLost: (CameraSession) -> Void
    // Restored pages may have only presentation history. Protocol work always
    // requires the real session; remembering a mode never creates one.
    private let session: CameraSession?
    private let presentationMode: CameraPresentationMode
    private var transferSession: CameraSession? { isSessionConnected ? session : nil }
    @AppStorage("tap_to_preview") private var tapToPreview = false
    @State private var selectedFile: CameraFile?
    @State private var previewAnchor: PhotoPreviewAnchorBounds?
    @State private var previewExpandedBurstIDs: Set<String> = []
    @Environment(\.displayScale) private var displayScale
    @State private var remoteEntryAtTop = true
    private var storageMode: TransferStorageMode {
        TransferStorageMode.restored(
            from: storageModeRaw.isEmpty ? nil : storageModeRaw,
            legacyByDate: UserDefaults.standard.bool(forKey: TransferStorageMode.legacyByDateKey)
        )
    }
    @AppStorage(TransferSaveDestination.persistenceKey) private var saveDestinationRaw = TransferSaveDestination.photoLibrary.rawValue
    private var saveDestination: TransferSaveDestination {
        TransferSaveDestination(rawValue: saveDestinationRaw) ?? .photoLibrary
    }
    /// Album mode ignores the folder wheels. Photos groups by capture date itself.
    private var effectiveStorageMode: TransferStorageMode {
        saveDestination == .photoLibrary ? .unified : storageMode
    }
    private var indexedTransferDirectory: URL? { saveDestination.transferRoot(userDirectory: directoryStore.directoryURL) }
    @State private var photoListScrollProxy: ScrollViewProxy?
    @State private var previewReturnFileID: UInt32?
    @State private var previewReturnNonce = 0
    @State private var showingFilter = false
    @SceneStorage("camera_workspace_queue") private var showingQueue = false
    @StateObject private var queueWorkspace = WorkspacePageClock(side: .right)
    @State private var filesScrollPosition = WorkspaceScrollPosition()
    @State private var queueScrollPosition = WorkspaceScrollPosition()
    @State private var queueControlActionNonce: UInt64 = 0
    @State private var queuePauseHint = PhotoListHintState()
    @AppStorage("defer_transfer_start") private var deferTransferStart = false
    @AppStorage(TransferStorageMode.persistenceKey) private var storageModeRaw = ""
    @AppStorage("collapse_burst_photos") private var collapseBurstPhotos = true
    @AppStorage("thumbnail_columns") private var thumbnailColumns = 3
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedBurstIDs: Set<String> = []
    @State private var previousBurstGroups: [BurstPhotoGroup] = []
    @State private var collapsedDays: Set<String> = []
    @State private var presentedSections: [PhotoDaySection] = []
    @State private var gridCache = PhotoListGridCache()
    @State private var thumbnailEntrance = PhotoThumbnailBatchEntrance()
    @State private var previewProjection = PhotoPreviewProjectionCache()
    @State private var presentedCameraFiles: [CameraFile] = []
    @State private var cameraRemovalAffectedDays: Set<String> = []
    @State private var cameraRemovalTask: Task<Void, Never>?
    @State private var collapsingDay: String?
    @State private var collapsingDayKeepCount = 0
    @State private var dateCollapseProgress: CGFloat = 1
    @State private var dateAnimationTask: Task<Void, Never>?
    @State private var recentlyExpandedDay: String?
    @State private var revealTick = 0
    @State private var filterRevealWindow = false
    @State private var revealWindowTask: Task<Void, Never>?
    @State private var burstAnimationBusy = false
    @State private var burstReflowActive = false
    @State private var activeBurstReflowID: String?
    @State private var burstAnimationTask: Task<Void, Never>?
    @StateObject private var backTop = PhotoListBackTopController()
    @State private var scrollGeometry = PhotoListGeometryCache()
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
    @StateObject private var remoteIntro = RemoteEntryIntroController()
    @SceneStorage("camera_workspace_intro_handled") private var remoteIntroHandled = false
    @State private var showingSettings = false
    @State private var transferDirectoryAttention = false
    @State private var signalAttention = PhotoListSignalAttentionClock()
    @State private var admissionHint = PhotoListHintState()
    @State private var effectPreviewSource: UIImage?
    @State private var effectPreviewExif: PhotoExif?
    @State private var effectPreviewSourceName = ""
    @State private var effectPreviewGeneration = 0
    @State private var effectPreviewRequested = false
    @State private var effectPreviewFileKey: String?
    @State private var effectPreviewAttemptKey: String?
    @State private var effectPreviewLoadingKey: String?
    @State private var topControlsVisible = true
    @State private var queueTargetBounds: CGRect = .zero
    @State private var queueFlights: [PhotoListQueueFlight] = []
    @State private var queueFlightTasks: [UUID: Task<Void, Never>] = [:]
    @State private var flightAdmissions = PhotoListFlightAdmissions()
    @State private var heldFlightCount = 0
    @State private var queueImpact = 0

    init(session: CameraSession?, listModel suppliedModel: PhotoListViewModel? = nil, presentationMode: CameraPresentationMode = .sta, queue: TransferQueue, queueModel suppliedQueueModel: TransferQueueViewModel? = nil, directory: DirectoryAccessStore = DirectoryAccessStore(), effectsStore: PhotoEffectsStore = PhotoEffectsStore(), isSessionConnected: Bool = true, onRetrySTA: @escaping () -> Void = {}, remotePresentation: Binding<Bool>? = nil, onTransportLost: @escaping (CameraSession) -> Void = { _ in }) {
        let listModel = suppliedModel ?? session.map { live in
            PhotoListViewModel.cached(session: live, onTransportLost: { onTransportLost(live) })
        } ?? PhotoListViewModel(disconnected: presentationMode)
        _model = ObservedObject(wrappedValue: listModel)
        self.presentationMode = session.map { CameraPresentationMode(isUSB: $0.isUSB, wirelessMode: $0.wirelessMode) }
            ?? presentationMode
        _queueModel = StateObject(wrappedValue: suppliedQueueModel ?? TransferQueueViewModel(queue: queue))
        _directoryStore = ObservedObject(wrappedValue: directory)
        self.effectsStore = effectsStore; self.isSessionConnected = isSessionConnected && session != nil
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

    private var scrollLayout: PhotoListScrollLayout {
        PhotoListScrollLayout(sections: presentedSections, burstIDs: model.burstIDByFile,
                              collapseBursts: collapseBurstPhotos, expandedBursts: expandedBurstIDs,
                              collapsedDays: collapsedDays, collapsingDay: collapsingDay,
                              keepCount: collapsingDayKeepCount)
    }

    private func updateBackTopPosition() {
        backTop.update(frames: scrollGeometry.scrollItemFrames, indices: scrollGeometry.scrollItemIndices,
                       viewport: photoListVisibleViewport, scale: displayScale)
    }

    var body: some View {
        #if DEBUG
        let _ = ButtonInteractionTrace.recordNow("files-workspace-body")
        #endif
        let layout = scrollLayout
        let grid = gridCache.snapshot(for: layout)
        return ZStack(alignment: .top) {
            ZTransferColors.background.ignoresSafeArea()
            if queueWorkspace.pages.contains(true) {
                TransferQueueView(model: queueModel, session: session, directory: directoryStore,
                                  isSessionConnected: isSessionConnected,
                                  onRetrySTA: onRetrySTA,
                                  showsTopControls: false,
                                  scrollPosition: queueScrollPosition,
                                  controlActionNonce: queueControlActionNonce,
                                  hasIndexedOriginal: { item in
                                      model.hasTransferredOriginal(item.file, folderName: item.destinationFolderName,
                                                                   directory: indexedTransferDirectory)
                                  },
                                  onNavigateBack: dismissQueuePage)
                .modifier(WorkspacePageEffect(frame: queueWorkspace.destination))
                .modifier(WorkspacePageInput(enabled: showingQueue))
                .transition(.identity)
                .zIndex(1)
            }
            if queueWorkspace.pages.contains(false) {
            ScrollViewReader { reader in
                ScrollView(showsIndicators: false) {
                    Color.clear.frame(height: 1).id("photo-list-top")
                        .background(WorkspaceScrollRestoration(position: filesScrollPosition))
                        .background(PhotoListScrollActivity(onScroll: { atTop in
                            if !atTop {
                                #if DEBUG
                                ButtonInteractionTrace.recordNow("photo-scroll")
                                #endif
                                remoteIntro.collapse()
                                remoteExpandedAwayFromTop = false
                            }
                        }, onActivityChanged: { backTop.setScrolling($0) }))
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
                                let allEntries = grid.entriesByDay[section.day] ?? []
                                let collapsingThis = collapsingDay == section.day
                                let displayedEntries = collapsingThis
                                    ? Array(allEntries.prefix(collapsingDayKeepCount))
                                    : allEntries
                                VStack(alignment: .leading, spacing: 0) {
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
                                            .animation(.interpolatingSpring(mass: 1, stiffness: 1500, damping: 77.459667),
                                                       value: collapsedDays.contains(section.day) || collapsingThis)
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
                                .accessibilityIdentifier("photo-date-\(section.day)")
                                Spacer(minLength: 0)
                                Button {
                                    enqueueSection(section.files, source: scrollGeometry.sectionEnqueueBounds[section.day])
                                } label: {
                                    Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(ZTransferColors.accentBlue)
                                        .frame(width: 40, height: 28)
                                }
                                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
                                .accessibilityIdentifier("enqueue-day-\(section.day)")
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: PhotoListSectionEnqueueBoundsPreferenceKey.self,
                                            value: [section.day: proxy.frame(in: .global)]
                                        )
                                    }
                                }
                                }
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: PhotoListScrollItemsPreferenceKey.self,
                                            value: ["header_\(section.day)": proxy.frame(in: .global)])
                                    }
                                }
                                // Android keeps this in the header even when
                                // closed; removing it at collapse completion
                                // made the following group jump by 10pt.
                                .padding(.bottom, 10)
                                if !collapsedDays.contains(section.day) || collapsingThis {
                                    LazyVGrid(columns: columns, spacing: 0) {
                                        ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { cellIndex, entry in
                                        let file = entry.firstFile
                                        let transferExiting = entry.isPhoto &&
                                            model.exitingTransferredFileIDs.contains(file.id)
                                        let activeBurstMember = burstReflowActive && entry.isPhoto &&
                                            model.burstIDByFile[file.id] == activeBurstReflowID
                                        VStack(alignment: .leading, spacing: 0) {
                                            if case let .burst(group) = entry {
                                                BurstThumbnailView(session: session, group: group,
                                                                   allowRemoteThumbnails: isSessionConnected && selectedFile == nil,
                                                                   loadEnabled: !collapsingThis,
                                                                   transfersBusy: queueModel.snapshot.isTransferring,
                                                                   transferred: group.files.allSatisfy { model.transferredFileIDs.contains($0.id) },
                                                                   expanded: expandedBurstIDs.contains(group.id),
                                                                   onExpand: { toggleBurst(group.id) },
                                                                   onEnqueue: {
                                                                       enqueueSection(group.files, source: visiblePhotoListCellBounds(
                                                                        .burstEnqueue(group.id), bounds: scrollGeometry.cellBounds, viewport: photoListVisibleViewport))
                                                                   }, onPreview: {
                                                                       guard !burstAnimationBusy, collapsingDay == nil,
                                                                             cameraRemovalAffectedDays.isEmpty else { return }
                                                                       handleLongPress(entry, file: file)
                                                                   })
                                            } else {
                                            CameraThumbnailView(session: session, file: file,
                                                                    allowRemoteThumbnail: isSessionConnected && selectedFile == nil,
                                                                    loadEnabled: !collapsingThis,
                                                                    transfersBusy: queueModel.snapshot.isTransferring,
                                                                    transferred: model.transferredFileIDs.contains(file.id),
                                                                    inBurst: model.burstIDByFile[file.id] != nil,
                                                                    queueTask: queueModel.task(for: file.id),
                                                                    progressModel: queueModel.progressModel)
                                                .accessibilityIdentifier("photo-cell-\(file.id)")
                                            }
                                        }
                                        .modifier(PhotoThumbnailBatchOpacity(entrance: thumbnailEntrance))
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
                                                    value: [entry.cellID: proxy.frame(in: .global)]
                                                )
                                                .preference(key: PhotoListScrollItemsPreferenceKey.self,
                                                            value: [entry.id: proxy.frame(in: .global)])
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
                                            delay: recentlyExpandedDay == section.day
                                                ? UInt64(min(cellIndex / columns.count, 4)) * 18_000_000
                                                : UInt64(min(cellIndex, 18)) * 15_000_000
                                        ))
                                        .transition(photoGridCellTransition(
                                            burstMember: activeBurstMember,
                                            cameraRemoval: cameraRemovalAffectedDays.contains(section.day)
                                        ))
                                        .modifier(PhotoCellInput(
                                            enabled: entry.isPhoto,
                                            duration: tapToPreview ? photoTransferLongPressDuration : photoPreviewLongPressDuration,
                                            feedbackForTransfer: tapToPreview,
                                            onTap: { handleTap(entry, file: file) },
                                            onHold: {
                                                guard !burstAnimationBusy, collapsingDay == nil,
                                                      cameraRemovalAffectedDays.isEmpty else { return }
                                                handleLongPress(entry, file: file)
                                            }
                                        ))
                                        .modifier(PhotoDateCellCollapse(progress: collapsingThis ? dateCollapseProgress : 1))
                                    }
                                }
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
                        if !isSessionConnected {
                            CameraDisconnectedState(
                                mode: presentationMode,
                                onRetrySTA: onRetrySTA
                            )
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
                                PhotoListRatingEmptyState(progress: model.ratingProgress, filter: model.filter,
                                                          protectionAvailable: model.protectionFilteringEnabled,
                                                          onClearFilter: {
                                                              showingFilter = false
                                                              model.clearFilter()
                                                          })
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
                .onAppear {
                    photoListScrollProxy = reader
                    scrollGeometry.scrollItemIndices = grid.indices
                    updateBackTopPosition()
                }
                .onDisappear { backTop.reset() }
                .onChange(of: layout) { layout in
                    scrollGeometry.scrollItemIndices = gridCache.snapshot(for: layout).indices
                    updateBackTopPosition()
                }
                .onPreferenceChange(PhotoListScrollItemsPreferenceKey.self) { frames in
                    scrollGeometry.scrollItemFrames = frames
                    updateBackTopPosition()
                }
                .onPreferenceChange(PhotoListViewportPreferenceKey.self) { bounds in
                    scrollGeometry.viewportBounds = bounds
                    updateBackTopPosition()
                }
                .onPreferenceChange(PhotoListCellBoundsPreferenceKey.self) { bounds in
                    // Lazy-grid cells unregister when they leave composition.
                    // Keep only the current preference snapshot so preview
                    // dismissal never flies toward a stale off-screen frame.
                    scrollGeometry.cellBounds = bounds
                }
                .onPreferenceChange(PhotoListSectionEnqueueBoundsPreferenceKey.self) { bounds in
                    scrollGeometry.sectionEnqueueBounds = bounds
                }
                .onPreferenceChange(PhotoListScrollOffsetKey.self) { value in
                    scrollGeometry.photoListScrollOffset = value
                    let atTop = PhotoListScrollActivity.isAtTop(offset: -value, scale: displayScale)
                    if remoteEntryAtTop != atTop { remoteEntryAtTop = atTop }
                    if atTop {
                        remoteExpandedAwayFromTop = false
                        backTop.finishReturn()
                    }
                }
                // Android's photo grid has no pull-to-refresh action. Adding
                // SwiftUI refreshable made a downward drag restart the camera
                // scan and thumbnail pipeline while the user was just scrolling.
                .overlay(alignment: .bottomTrailing) {
                    if backTop.isVisible {
                        Button {
                            backTop.beginReturn()
                            // Basic functional return; animation fidelity is deferred.
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { reader.scrollTo("photo-list-top", anchor: .top) }
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
            }
            .modifier(WorkspacePageEffect(frame: queueWorkspace.source))
            .modifier(WorkspacePageInput(enabled: !showingQueue && !queueWorkspace.transitioning))
            .transition(.identity)
            .zIndex(0)
            }
            if selectedFile != nil { previewOverlay }
            workspaceTopControls
            queueFlightOverlay
            PhotoListHint(state: admissionHint)
            PhotoListHint(state: queuePauseHint)
                .onDisappear { queuePauseHint.stop() }
            DebugPhotoProtectionPanel(
                isSTA: presentationMode == .sta,
                files: model.displayedFiles,
                session: isSessionConnected ? session : nil
            )
        }
        .modifier(WorkspacePageLifecycle(clock: queueWorkspace, presented: showingQueue))
        #if DEBUG
        .task {
            // Explicit local benchmark: no XCTest/AX snapshot polling while
            // measuring the real first mount. Never runs in a normal launch.
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--list-admission-ui-test"),
                  arguments.contains("--photo-hold-trace"),
                  arguments.contains("--monitor-cold-benchmark") else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                ButtonInteractionTrace.reset()
                for _ in 0..<2 {
                    openRemote()
                    try await Task.sleep(for: .seconds(2))
                    showingRemote = false
                    try await Task.sleep(for: .seconds(1))
                }
                let result = URL.documentsDirectory.appendingPathComponent("monitor-cold-benchmark.json")
                try Data(ButtonInteractionTrace.snapshot().utf8).write(to: result, options: .atomic)
            } catch { /* Cancellation discards this diagnostic run. */ }
        }
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--list-admission-ui-test") {
                Text("flights=\(queueFlights.count);held=\(heldFlightCount)")
                    .font(.system(size: 8)).allowsHitTesting(false)
                    .accessibilityIdentifier("admission-flight-state")
            }
        }
        #endif
        .onPreferenceChange(PhotoListQueueTargetPreferenceKey.self) { queueTargetBounds = $0 }
        .onChange(of: session.map(ObjectIdentifier.init)) { _ in
            // Keep the displayed effect sample, but reject work from the old
            // protocol owner and allow an unfinished request to retry.
            effectPreviewGeneration &+= 1
            effectPreviewLoadingKey = nil
            effectPreviewAttemptKey = nil
            if effectPreviewRequested { requestEffectPreview() }
        }
        .task(id: PhotoListSessionTaskID(session: session.map(ObjectIdentifier.init), value: isSessionConnected)) {
            model.useOriginalStore(queueModel.originalStore)
            refreshTransferIndex()
            if showingRemote { showingQueue = false }
            if presentedSections.isEmpty {
                presentedSections = model.sections
                presentedCameraFiles = model.displayedFiles
            }
            queueModel.attach(session: transferSession, directory: indexedTransferDirectory)
            guard isSessionConnected else {
                model.transportDidDisconnect()
                return
            }
            await session?.setPreferHighThroughputTransfers(!showingRemote)
            model.setNewMediaHandler { files in
                // Read at the new-file event, not when the page first appeared.
                // Changing the wheel does not rescan or replay rejected files.
                let mode = AutoTransferMode.load()
                let deferStart = UserDefaults.standard.bool(forKey: "defer_transfer_start")
                let destination = TransferSaveDestination.load()
                let storage = destination == .photoLibrary ? TransferStorageMode.unified : TransferStorageMode.load()
                Task { @MainActor in
                    let directory: URL?
                    if destination == .photoLibrary, !deferStart {
                        guard await PhotoLibraryTransferAccess.requestFullAccess() == .full else {
                            self.showPhotoAccessHint()
                            return
                        }
                        directory = PhotoLibraryTransferStaging.url
                    } else {
                        directory = destination.transferRoot(userDirectory: self.directoryStore.directoryURL)
                    }
                    guard let directory else { return }
                    self.queueModel.enqueueAutomatic(files, mode: mode, session: self.transferSession, directory: directory,
                                                     autoStart: !deferStart, storageMode: storage,
                                                     effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
                }
            }
            model.load()
        }
        // Android's MainScreen LaunchedEffect runs once when its owner enters
        // composition as well as on later changes. A plain onChange misses an
        // already-running queue when this view is rebuilt for a recovered
        // CameraSession, allowing catalog/thumbnail work to compete with the
        // transfer. task(id:) provides the same initial synchronization and
        // cancels a stale write if the busy state flips again immediately.
        .task(id: PhotoListSessionTaskID(session: session.map(ObjectIdentifier.init), value: queueModel.snapshot.isTransferring)) {
            let busy = queueModel.snapshot.isTransferring
            model.setTransferBusy(busy)
            await session?.setTransfersBusy(busy)
        }
        .task(id: PhotoListSessionTaskID(session: session.map(ObjectIdentifier.init), value: !showingQueue && !showingRemote)) {
            // Android removes FileListScreen's LaunchedEffect when navigating
            // to queue/remote. These iOS routes keep the parent view alive, so
            // cancel explicitly while hidden instead of spending a reminder.
            guard !showingQueue, !showingRemote, !remoteIntroHandled else { return }
            await remoteIntro.run(onStarted: { remoteIntroHandled = true })
        }
        .onChange(of: showingRemote) { remote in
            if remote {
                showingQueue = false
                cancelListQueueFlights()
            }
            // MainActivity.shouldPreferHighThroughputTransfers: both files and
            // transfer routes enable this; monitoring disables it.
            Task { await session?.setPreferHighThroughputTransfers(!remote) }
        }
        .onDisappear {
            cancelListQueueFlights()
            thumbnailEntrance.update(hasItems: false)
            signalAttention.stop()
            admissionHint.stop()
            cameraRemovalTask?.cancel()
            dateAnimationTask?.cancel()
            // A hidden workspace can retain its state. Cancellation must not
            // leave it stuck in a half-collapsed grid when the user returns.
            if let day = collapsingDay {
                collapsedDays.insert(day)
                collapsingDay = nil
                collapsingDayKeepCount = 0
                dateCollapseProgress = 1
            }
            revealWindowTask?.cancel()
            recentlyExpandedDay = nil
            filterRevealWindow = false
            burstAnimationTask?.cancel()
            Task { await session?.setPreferHighThroughputTransfers(false) }
        }
        .onChange(of: showingQueue) { visible in
            if visible { cancelListQueueFlights() }
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
        .onAppear { thumbnailEntrance.update(hasItems: !presentedSections.isEmpty) }
        .onChange(of: presentedSections.isEmpty) { thumbnailEntrance.update(hasItems: !$0) }
        .onChange(of: model.displayedFiles) { files in
            presentedCameraFiles = files
            // Filters can temporarily hide complete date groups. Only an
            // authoritative catalog change may retire a remembered choice.
            guard !collapsedDays.isEmpty else { return }
            let valid = Set(files.map { file in
                guard let value = file.captureDate, value.count >= 8 else { return PhotoCatalogGrouping.unknownDay }
                return String(value.prefix(8))
            })
            let retained = collapsedDays.intersection(valid)
            if retained != collapsedDays { collapsedDays = retained }
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
            refreshTransferIndex()
        }
        .onReceive(directoryStore.selectionChanges) { directory in
            guard saveDestination == .folder else { return }
            queueModel.attach(session: transferSession, directory: directory)
            refreshTransferIndex(reset: true)
        }
        .onChange(of: storageModeRaw) { _ in
            refreshTransferIndex()
        }
        .onChange(of: saveDestinationRaw) { _ in
            queueModel.attach(session: transferSession, directory: indexedTransferDirectory)
            refreshTransferIndex(reset: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: FreeUsageStore.changed)) { notification in
            guard let left = notification.userInfo?["threshold"] as? Int else { return }
            showUsageHint(AppLocalized.formattedResource("quota_left_hint", ["%1$d": String(left), "%2$d": "25"]))
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteTrialNotice.returned)) { _ in
            consumeRemoteTrialNotice()
        }
        .onAppear { consumeRemoteTrialNotice() }
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
        .workspaceMonitor(isPresented: $internalShowingRemote, onDismiss: RemoteTrialNotice.returnedToList) {
            RemoteView(session: session, queueModel: queueModel, presentationMode: presentationMode,
                       isSessionConnected: isSessionConnected,
                       onClose: { internalShowingRemote = false },
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
                           if let session { onTransportLost(session) }
                       })
                .id(session.map(ObjectIdentifier.init))
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
                    effectPreviewExif: effectPreviewExif, effectPreviewSourceName: effectPreviewSourceName,
                    onEffectPreviewRequested: requestEffectPreview,
                    onPhotoLoadingRangeChanged: model.setPhotoLoadingRange
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
                    ratingProgress: model.ratingProgress,
                    showProtectionFilter: model.protectionFilteringEnabled,
                    onChange: applyFilter,
                    onReset: model.clearFilter
                )
            }
        }
        .previewPhotoEffectsPresentation()
    }

    @ViewBuilder private var previewOverlay: some View {
        if let session {
        let files = model.previewFiles
        PhotoPreviewView(session: session, queueModel: queueModel, files: files, projection: previewProjection,
                         effectsStore: effectsStore, effectsDirectory: directoryStore,
                         isSessionConnected: isSessionConnected,
                         burstIDByFile: model.burstIDByFile,
                         transferredFileIDs: model.transferredFileIDs, selectedFile: $selectedFile,
                         directory: indexedTransferDirectory,
                         storageMode: effectiveStorageMode,
                         queueTarget: queueTargetBounds == .zero ? nil : queueTargetBounds,
                         initialAnchor: previewAnchor?.image,
                         initialVisibleAnchor: previewAnchor?.visible,
                         initialExpandedBurstIDs: previewExpandedBurstIDs,
                         collapseBursts: collapseBurstPhotos,
                         onBurstChanged: { id, expanded in
                             if expanded { expandedBurstIDs.insert(id) }
                             else { expandedBurstIDs.remove(id) }
                         }) { file in
            beginTransfer([file], fromPreview: true, startsNow: !deferTransferStart) { directory, mode in
                if self.deferTransferStart {
                    self.queueModel.enqueue(file, storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
                } else {
                    self.queueModel.enqueue(file, autoStart: self.transferSession, directory: directory, storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
                }
            }
        } onEnqueueBurst: { burstFiles in
            return beginTransfer(burstFiles, fromPreview: true, startsNow: !deferTransferStart) { directory, mode in
                if self.deferTransferStart {
                    self.queueModel.enqueue(burstFiles, storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
                } else {
                    self.queueModel.enqueue(burstFiles, autoStart: self.transferSession, directory: directory, storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
                }
            }
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
        } onCropConfirmed: { file, selection in
            let hasDirectory = saveDestination == .photoLibrary || directoryStore.directoryURL != nil
            switch CropPreviewAdmission(hasDirectory: hasDirectory, connected: isSessionConnected) {
            case .directoryRequired:
                selectedFile = nil
                requestTransferDirectory()
                return false
            case .disconnected:
                signalAttention.trigger()
                admissionHint.show(AppLocalized.resource("camera_not_connected"))
                return false
            case .accepted: break
            }
            let directory: URL?
            let mode: TransferStorageMode
            if saveDestination == .photoLibrary {
                mode = .unified
                if deferTransferStart {
                    directory = nil
                } else {
                    guard await PhotoLibraryTransferAccess.requestFullAccess() == .full else {
                        showPhotoAccessHint()
                        return false
                    }
                    directory = PhotoLibraryTransferStaging.url
                }
            } else {
                mode = storageMode
                directory = deferTransferStart ? nil : directoryStore.directoryURL
            }
            let accepted = await queueModel.acceptCrop(file, selection: selection, storageMode: mode,
                session: deferTransferStart ? nil : transferSession,
                directory: directory, effects: effectsStore.settings, photoEffectsEnabled: effectsStore.isEnabled)
            if accepted { admissionHint.show(AppLocalized.resource("crop_added")) }
            return accepted
        }
        .onAppear { model.pauseForPreview() }
        .onDisappear {
            model.resumeAfterPreview()
            model.wakeThumbnailFill()
        }
        }
    }

    private var photoListTopLeftControls: some View {
        HStack(spacing: 8) {
            Button {
                ZTransferHaptics.shared.play(.navigation)
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

            CameraSignalControl(isUSB: presentationMode == .usb,
                                wirelessMode: presentationMode == .sta ? .sta : .ap,
                                connected: isSessionConnected,
                                height: photoListTopControlsHeight,
                                onRetrySTA: onRetrySTA)
                .modifier(PhotoListSignalAttention(clock: signalAttention))

            let filterPalette = zTransferButtonAccentPalette(
                skin: .init(storedValue: skinPreset),
                scheme: colorScheme,
                active: ZTransferColors.accentYellow
            )
            Button {
                ZTransferHaptics.shared.play(.navigation)
                showingFilter.toggle()
            } label: {
                PhotoListFilterIcon(
                    active: model.filter.isActive(protectionAvailable: model.protectionFilteringEnabled),
                    color: model.filter.isActive(protectionAvailable: model.protectionFilteringEnabled) ? filterPalette.active : filterPalette.inactive
                )
                    .frame(width: 19, height: 19)
                    .frame(width: photoListCompactButtonWidth,
                           height: photoListTopControlsHeight)
            }
            .buttonStyle(ZTransferGlassButtonStyle(
                cornerRadius: 22,
                active: model.filter.isActive(protectionAvailable: model.protectionFilteringEnabled),
                activeColor: filterPalette.material,
                activeOutline: true,
                materialContentColor: model.filter.isActive(protectionAvailable: model.protectionFilteringEnabled)
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
            ZStack(alignment: .leading) {
                if queueWorkspace.pages.contains(false) {
                    ZStack(alignment: .leading) {
                        if topControlsVisible { photoListTopLeftControls }
                    }
                    .modifier(WorkspacePageEffect(frame: queueWorkspace.source))
                    .modifier(WorkspacePageInput(enabled: !showingQueue && !queueWorkspace.transitioning))
                    .transition(.identity)
                }
                if queueWorkspace.pages.contains(true) {
                    queuePageTopControls
                        // Give the fixed composite its 16pt shadow margin,
                        // without shifting controls or changing hit bounds.
                        .padding(.bottom, 16)
                        .modifier(WorkspacePageEffect(frame: queueWorkspace.header))
                        .padding(.bottom, -16)
                        .modifier(WorkspacePageInput(enabled: showingQueue))
                        .transition(.identity)
                }
            }

            Spacer(minLength: 0)
        }
        // The trailing cluster is anchored to the viewport, not negotiated
        // with the intrinsic widths of the leading controls in one HStack.
        .overlay(alignment: .topTrailing) { queueTopRightControls }
        .overlay(alignment: .topTrailing) {
            QueueTopFlightAnchor()
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
        .onPreferenceChange(PhotoListTopControlsBoundsPreferenceKey.self) {
            scrollGeometry.topControlsBounds = $0
        }
    }

    /// FilesQueueWorkspace's fixed header fades with the incoming page
    /// (100+200ms), and exits in 80ms. The trailing capsule never translates.
    private var queuePageTopControls: some View {
        HStack(spacing: 8) {
            Button(action: dismissQueuePage) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: photoListCompactButtonWidth,
                           height: photoListTopControlsHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(ZTransferGlassButtonStyle.iconControl(cornerRadius: 22))
            .accessibilityIdentifier("workspace-queue-back")

            CameraSignalControl(isUSB: presentationMode == .usb,
                                wirelessMode: presentationMode == .sta ? .sta : .ap,
                                connected: isSessionConnected,
                                height: photoListTopControlsHeight,
                                onRetrySTA: onRetrySTA)
                .modifier(PhotoListSignalAttention(clock: signalAttention))
        }
        .transition(.opacity)
    }

    private func presentQueuePage() {
        guard !showingQueue else { return }
        showingQueue = true
    }

    private func dismissQueuePage() {
        guard showingQueue else { return }
        showingQueue = false
    }

    /// Android keeps queue execution and the queue pill outside the files ↔
    /// transfer page transition. Reusing this group in both pages preserves
    /// one source of truth for start/pause availability and pill animation.
    private var queueTopRightControls: some View {
        let executionMode = queueModel.snapshot.executionControl
        let canStart = indexedTransferDirectory != nil && (isSessionConnected ||
            !queueModel.snapshot.items.contains { item in
                item.status == .waiting && !model.hasTransferredOriginal(item.file,
                    folderName: item.destinationFolderName, directory: indexedTransferDirectory)
            })
        return SharedQueueControlsLayout {
            QueueTopPresence(visible: executionMode != nil && (showingQueue || selectedFile == nil),
                             kind: .execution) {
                QueueTopExecutionButton(control: executionMode,
                    pauseRequested: queueModel.snapshot.pauseAfterCurrent, startEnabled: canStart) { control in
                    switch control {
                    case .pause:
                        guard queueModel.snapshot.isTransferring,
                              !queueModel.snapshot.pauseAfterCurrent else { return }
                        queueControlActionNonce &+= 1
                        ZTransferHaptics.shared.play(.action)
                        queueModel.pause()
                        queuePauseHint.show(AppLocalized.resource("pause_after_current_hint"), duration: .milliseconds(2200))
                    case .start:
                        guard canStart else { return }
                        queueControlActionNonce &+= 1
                        ZTransferHaptics.shared.play(.action)
                        Task { @MainActor in
                            guard let directory = await self.directoryForTransferStart() else { return }
                            self.queueModel.start(session: self.transferSession, directory: directory)
                        }
                    }
                }
            }
            LiveQueuePill(snapshot: queueModel.snapshot,
                    progressModel: queueModel.progressModel, heldCount: heldFlightCount,
                    visible: !showingQueue, onClick: presentQueuePage)
                    .accessibilityLabel(AppLocalized.resource("cd_transfer"))
                    .accessibilityIdentifier("workspace-queue-open")
                    .allowsHitTesting(!showingQueue)
                    // The named outer wrapper must leave accessibility too;
                    // hiding its Button alone leaves a discoverable zero-width
                    // transfer control on the queue page.
                    .accessibilityHidden(showingQueue)
        }
        .modifier(QueueControlsCatchEffect(trigger: queueImpact))
    }

    /// Android requests the latest visible file on entering Settings: publish
    /// its cached thumbnail first, then upgrade the same identity to the FHD
    /// preview and EXIF. A late response for an older file is discarded.
    private func requestEffectPreview() {
        effectPreviewRequested = true
        guard let session, let file = model.latestEffectPreviewFile else { return }
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
                    effectPreviewSourceName = file.fileName
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
                effectPreviewSourceName = file.fileName
                effectPreviewExif = result.1
                effectPreviewSource = UIImage(data: previewData)
            }
        }
    }

    @ViewBuilder
    private var remoteEntryOverlay: some View {
        let remoteExpanded = remoteEntryAtTop || remoteExpandedAwayFromTop || remoteIntro.expanded
        VStack(alignment: .leading, spacing: 8) {
            if let remoteEntryHint {
                Text(remoteEntryHint)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ZTransferColors.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(ZTransferHintSurface())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            RemoteEntryButton(expanded: remoteExpanded, intro: remoteIntro.expanded,
                              busy: queueModel.snapshot.isTransferring) {
                // Even a blocked entry or a peek click ends the V2 campaign.
                remoteIntro.markUsed()
                if remoteExpanded {
                    openRemote()
                } else {
                    ZTransferHaptics.shared.play(.navigation)
                    remoteExpandedAwayFromTop = true
                }
            }
        }
        .padding(.bottom, 40)
        .animation(ZTransferMotion.standard, value: remoteEntryHint)
    }

    private func openRemote() {
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
        guard PremiumAccess.shared.isPro || FreeUsageStore.shared.snapshot().monitoringLeft > 0 else {
            showUsageHint(AppLocalized.resource("remote_trial_ended"))
            return
        }
        remoteIntro.collapse()
        remoteExpandedAwayFromTop = false
        showingRemote = true
    }

    private func showUsageHint(_ text: String) {
        let id = UUID()
        remoteEntryHintID = id
        withAnimation(ZTransferMotion.standard) { remoteEntryHint = text }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled, remoteEntryHintID == id else { return }
            withAnimation(ZTransferMotion.standard) { remoteEntryHint = nil }
        }
    }

    private func consumeRemoteTrialNotice() {
        guard !showingRemote, RemoteTrialNotice.pending else { return }
        RemoteTrialNotice.pending = false
        showUsageHint(AppLocalized.resource("remote_trial_ended"))
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
        let currentCameraFiles = model.displayedFiles
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

    private func applyFilter(_ requested: PhotoFilterState) {
        let filter = model.filterForPersistence(requested)
        // Android keeps the rating loader and its date range out of the
        // visible-grid filter. Only a concrete star (or another filter field)
        // starts the 600 ms cascade/reflow animation.
        var lifecycleOnly = model.filter
        lifecycleOnly.ratingEnabled = filter.ratingEnabled
        lifecycleOnly.ratingDays = filter.ratingDays
        let changesList = lifecycleOnly != filter
        if changesList {
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
        }
        model.setFilter(filter)
    }

    private func toggleDateSection(_ section: PhotoDaySection, entries: [PhotoGridEntry]) {
        guard collapsingDay == nil, !burstAnimationBusy,
              cameraRemovalAffectedDays.isEmpty else { return }
        #if DEBUG
        ButtonInteractionTrace.recordNow(collapsedDays.contains(section.day) ? "date-group-expand" : "date-group-collapse")
        #endif
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

        let viewport = photoListVisibleViewport
        let lastVisible = entries.indices.last { index in
            visiblePhotoListCellBounds(entries[index].cellID, bounds: scrollGeometry.cellBounds, viewport: viewport) != nil
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
            // Commit the retained visible grid before animating its height.
            // Yield alone may resume within the insertion transaction.
            do { try await ZTransferNextDisplayFrame.wait() }
            catch { return }
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
        guard let first = files.first else { return }
        let started = beginTransfer(files, startsNow: !deferTransferStart) { directory, mode in
            if self.deferTransferStart {
                self.queueModel.enqueue(files, storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
            } else {
                self.queueModel.enqueue(files, autoStart: self.transferSession, directory: directory,
                                       storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
            }
        }
        guard started else { return }
        ZTransferHaptics.shared.play(.enqueue)
        startListQueueFlight(for: first, count: files.count, from: source, packFiles: files)
    }

    private func handleTap(_ entry: PhotoGridEntry, file: CameraFile) {
        if case .burst = entry { return }
        if tapToPreview {
            ZTransferHaptics.shared.play(.preview)
            openPreview(file, anchor: .photo(file.id))
        } else {
            enqueueFileFromList(file)
        }
    }

    /// Android swaps the single-photo tap/hold actions when “tap to preview”
    /// is enabled. The burst collection keeps its dedicated contract: tap its
    /// arrow/action controls, hold the image area to preview the first member.
    private func handleLongPress(_ entry: PhotoGridEntry, file: CameraFile) {
        #if DEBUG
        ButtonInteractionTrace.recordNow("photo-long-press")
        #endif
        if case let .burst(group) = entry {
            ZTransferHaptics.shared.play(.preview)
            openPreview(group.files[0], anchor: .burst(group.id), expandingBurst: group.id)
        } else if tapToPreview {
            enqueueFileFromList(file)
        } else {
            ZTransferHaptics.shared.play(.preview)
            openPreview(file, anchor: .photo(file.id))
        }
    }

    private func enqueueFileFromList(_ file: CameraFile) {
        let started = beginTransfer([file], startsNow: !deferTransferStart) { directory, mode in
            if self.deferTransferStart {
                self.queueModel.enqueue(file, storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
            } else {
                self.queueModel.enqueue(file, autoStart: self.transferSession, directory: directory,
                                       storageMode: mode, effects: self.effectsStore.settings, photoEffectsEnabled: self.effectsStore.isEnabled)
            }
        }
        guard started else { return }
        ZTransferHaptics.shared.play(.enqueue)
        startListQueueFlight(for: file, from: visiblePhotoListCellBounds(
            .photo(file.id), bounds: scrollGeometry.cellBounds, viewport: photoListVisibleViewport))
    }

    /// Returns true when the transfer is admitted immediately. The first album
    /// authorization prompt returns false and enqueues only after the user allows
    /// full photo access, so a rejected prompt never starts a flight.
    @discardableResult
    private func beginTransfer(_ files: [CameraFile], fromPreview: Bool = false, startsNow: Bool,
                               enqueue: @escaping (URL, TransferStorageMode) -> Void) -> Bool {
        guard !files.isEmpty else { return false }
        switch saveDestination {
        case .folder:
            guard let directory = directoryStore.directoryURL else {
                if fromPreview { selectedFile = nil }
                requestTransferDirectory()
                return false
            }
            guard model.canEnqueueManually(files, connected: isSessionConnected,
                                          directory: directory, storageMode: storageMode) else {
                signalAttention.trigger()
                admissionHint.show(AppLocalized.resource("camera_not_connected"))
                return false
            }
            enqueue(directory, storageMode)
            return true
        case .photoLibrary:
            let directory = PhotoLibraryTransferStaging.url
            guard model.canEnqueueManually(files, connected: isSessionConnected,
                                          directory: directory, storageMode: .unified) else {
                signalAttention.trigger()
                admissionHint.show(AppLocalized.resource("camera_not_connected"))
                return false
            }
            guard startsNow else {
                enqueue(directory, .unified)
                return true
            }
            let status = PhotoLibraryTransferAccess.currentStatus()
            if PhotoLibraryAccess.decide(status) == .full {
                enqueue(directory, .unified)
                return true
            }
            guard status == .notDetermined else {
                showPhotoAccessHint()
                return false
            }
            Task { @MainActor in
                guard await PhotoLibraryTransferAccess.requestFullAccess() == .full else {
                    self.showPhotoAccessHint()
                    return
                }
                enqueue(directory, .unified)
            }
            return false
        }
    }

    private func directoryForTransferStart() async -> URL? {
        switch saveDestination {
        case .folder:
            guard let directory = directoryStore.directoryURL else {
                requestTransferDirectory()
                return nil
            }
            return directory
        case .photoLibrary:
            guard await PhotoLibraryTransferAccess.requestFullAccess() == .full else {
                showPhotoAccessHint()
                return nil
            }
            return PhotoLibraryTransferStaging.url
        }
    }

    private func refreshTransferIndex(reset: Bool = false) {
        let directory = indexedTransferDirectory
        model.refreshTransferredIDs(directory: directory, storageMode: effectiveStorageMode, resetDirectoryIndex: reset)
        if saveDestination == .photoLibrary, let directory {
            PhotoLibraryTransferLedger.shared.apply(to: queueModel.originalStore, root: directory)
        }
    }

    private func showPhotoAccessHint() {
        let hintID = UUID()
        remoteEntryHintID = hintID
        withAnimation(ZTransferMotion.standard) {
            remoteEntryHint = AppLocalized.resource("transfer_photo_access_blocked")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, remoteEntryHintID == hintID else { return }
            withAnimation(ZTransferMotion.standard) { remoteEntryHint = nil }
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

    private func openPreview(_ file: CameraFile, anchor: PhotoListCellID, expandingBurst: String? = nil) {
        #if DEBUG
        ButtonInteractionTrace.recordNow("preview-request")
        #endif
        // FileListScreen.onPreviewBurst expands only the opening snapshot.
        // The underlying grid is reconciled when returning to a member.
        previewExpandedBurstIDs = expandedBurstIDs
        if let expandingBurst { previewExpandedBurstIDs.insert(expandingBurst) }
        previewAnchor = photoPreviewAnchorBounds(anchor, bounds: scrollGeometry.cellBounds, viewport: photoListVisibleViewport)
        selectedFile = file
    }

    /// Measure both the ScrollView and the permanent top slot. Depending on the
    /// OS, `safeAreaInset` can report the ScrollView frame before or after its
    /// safe region is reduced; using the measured slot edge avoids subtracting
    /// its 36pt twice on either implementation.
    private var photoListVisibleViewport: CGRect {
        let measured = scrollGeometry.viewportBounds
        let base = measured.width > 0 && measured.height > 0
            ? measured
            : UIScreen.main.bounds
        let measuredControls = scrollGeometry.topControlsBounds
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
    private func preparePreviewDismissTarget(_ file: CameraFile) async -> PhotoPreviewAnchorBounds? {
        let sections = model.sections
        let targetDay = await Task.detached(priority: .userInitiated) {
            sections.first { $0.files.contains { $0.id == file.id } }?.day
        }.value
        guard !Task.isCancelled, let targetDay, !collapsedDays.contains(targetDay) else { return nil }

        if collapseBurstPhotos,
           let burstID = model.burstIDByFile[file.id],
           !expandedBurstIDs.contains(burstID) {
            expandedBurstIDs.insert(burstID)
            do { try await ZTransferNextDisplayFrame.wait() } catch { return nil }
        }

        let viewport = photoListVisibleViewport
        if let visible = photoPreviewAnchorBounds(.photo(file.id), bounds: scrollGeometry.cellBounds, viewport: viewport) {
            return visible
        }
        guard let reader = photoListScrollProxy else { return nil }

        // Reuse the grid's already-built projection (including date headers),
        // rather than rebuilding every burst and allocating a second flat album.
        let indices = gridCache.snapshot(for: scrollLayout).indices
        guard let targetIndex = indices["photo_\(file.id)"] else { return nil }
        let visibleIndex = scrollGeometry.scrollItemFrames.lazy
            .filter { $0.value.intersects(viewport) }.compactMap { indices[$0.key] }.min() ?? targetIndex
        let runway = min(max(thumbnailColumns, 1), 4) * 3
        if abs(targetIndex - visibleIndex) > runway * 2 {
            let nearbyIndex = targetIndex > visibleIndex
                ? max(0, targetIndex - runway)
                : min(indices.count - 1, targetIndex + runway)
            if let nearby = indices.first(where: { $0.value == nearbyIndex })?.key {
                reader.scrollTo(nearby, anchor: .top)
                do { try await ZTransferNextDisplayFrame.wait() } catch { return nil }
            }
        }
        let columns = CGFloat(normalizedThumbnailColumns(thumbnailColumns))
        let itemHeight = scrollGeometry.cellBounds[.photo(file.id)]?.height
            ?? max(1, (viewport.width - 24 - (columns - 1) * 6) / columns)
        let targetAnchor = UnitPoint(x: 0.5,
            y: photoPreviewReturnAnchor(viewportHeight: viewport.height, itemHeight: itemHeight))
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) {
            reader.scrollTo("photo_\(file.id)", anchor: targetAnchor)
        }
        do {
            try await Task.sleep(nanoseconds: 280_000_000)
            try await ZTransferNextDisplayFrame.wait()
        } catch { return nil }
        return photoPreviewAnchorBounds(.photo(file.id), bounds: scrollGeometry.cellBounds, viewport: photoListVisibleViewport)
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
        from source: CGRect?,
        packFiles: [CameraFile] = []
    ) {
        let screen = UIScreen.main.bounds
        guard let admission = flightAdmissions.admit(source: source, viewport: photoListVisibleViewport,
                                                     count: count) else { return }
        let from = admission.source
        let target = queueTargetBounds.isEmpty || queueTargetBounds.isInfinite || queueTargetBounds.isNull
            ? CGRect(x: screen.maxX - 13, y: 48, width: 1,
                     height: photoListTopControlsHeight)
            : queueTargetBounds
        let id = admission.id
        let flightCount = admission.count
        let visiblePackCandidates = count > 1 ? makeQueueFlightPacks(packFiles) : []
        let topImage = session?.memoryThumbnailImage(file: file)
        let packDuration = visiblePackCandidates.isEmpty ? 0.0 : 0.42
        beginQueueFlightHold(flightCount)
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
        queueFlightTasks[id] = Task { @MainActor in
            // startedAt is immutable and 32 ms in the future.
            // The native display clock crosses that boundary, so the animation
            // no longer depends on a second parent-state mutation being
            // delivered after insertion.
            try? await Task.sleep(nanoseconds: UInt64((0.032 + packDuration + 0.56) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finishListQueueFlight(id, caught: true)
        }
    }

    private func finishListQueueFlight(_ id: UUID, caught: Bool) {
        guard let count = flightAdmissions.finish(id) else { return }
        queueFlights.removeAll { $0.id == id }
        queueFlightTasks.removeValue(forKey: id)?.cancel()
        finishQueueFlightHold(count, caught: caught)
    }

    private func cancelListQueueFlights() {
        for id in flightAdmissions.activeIDs { finishListQueueFlight(id, caught: false) }
    }

    /// Freeze the number already visible before scheduling the real enqueue.
    /// The queue actor and the flight layer can now publish in either order
    /// without exposing the newly tapped task before the card reaches the pill.
    private func beginQueueFlightHold(_ count: Int) {
        let amount = max(0, count)
        guard amount > 0 else { return }
        heldFlightCount += amount
    }

    private func finishQueueFlightHold(_ count: Int, caught: Bool) {
        heldFlightCount = max(0, heldFlightCount - max(0, count))
        if caught { queueImpact &+= 1 }
    }

    private func makeQueueFlightPacks(_ files: [CameraFile]) -> [PhotoListQueuePackSoul] {
        let viewport = photoListVisibleViewport
        var candidates: [PhotoListQueuePackSoul] = []
        for file in files {
            guard let bounds = visiblePhotoListCellBounds(.photo(file.id), bounds: scrollGeometry.cellBounds,
                                                          viewport: viewport) else { continue }
            candidates.append(PhotoListQueuePackSoul(
                bounds: bounds,
                image: session?.memoryThumbnailImage(file: file)
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
        let count = flight.count > 1 ? 3 : 1
        let destination = CGPoint(x: flight.from.midX - viewport.minX, y: flight.from.midY - viewport.minY)
        let end = CGPoint(x: target.maxX - 28 - viewport.minX, y: target.midY - viewport.minY)
        let packSpecs = flight.packs.map {
            QueueFlightLayerSpec(image: $0.image, size: $0.bounds.size, corner: 8,
                                 background: UIColor(ZTransferColors.accentBlue.opacity(0.4)))
        }
        let cardSpecs = (0..<count).map { layer in
            QueueFlightLayerSpec(image: layer == count - 1 ? flight.image : nil,
                size: CGSize(width: 44, height: 44), corner: 9,
                borderAlpha: layer == count - 1 && flight.image != nil ? 0.8 : 0,
                background: UIColor(ZTransferColors.accentBlue.opacity(layer == count - 1 ? 1 : 0.35)),
                showsPlaceholder: layer == count - 1 && flight.image == nil)
        }
        QueueFlightLayers(startedAt: flight.startedAt, duration: flight.packDuration + 0.56,
                          specs: packSpecs + cardSpecs) { elapsed in
            let pack = flight.packDuration > 0 ? CGFloat(min(max(elapsed / flight.packDuration, 0), 1)) : 1
            let t = queueFlightEasedProgress(CGFloat(min(max((elapsed - flight.packDuration) / 0.56, 0), 1)))
            var frames = flight.packs.enumerated().map { index, soul in
                let step: CGFloat = flight.packs.count <= 1 ? 0 : 0.28 / CGFloat(flight.packs.count - 1)
                let span: CGFloat = flight.packs.count <= 1 ? 1 : 0.72
                let p = min(max((pack - CGFloat(index) * step) / span, 0), 1)
                let rise = min(p / 0.3, 1)
                let suck = pow(min(max((p - 0.3) / 0.7, 0), 1), 2)
                let start = CGPoint(x: soul.bounds.midX - viewport.minX, y: soul.bounds.midY - viewport.minY - 10 * rise)
                return QueueFlightLayerFrame(center: CGPoint(x: start.x + (destination.x - start.x) * suck,
                    y: start.y + (destination.y - start.y) * suck), scale: (1 + 0.06 * rise) * (1 - 0.85 * suck),
                    alpha: p <= 0 || p >= 1 ? 0 : 0.75 * rise * (1 - 0.3 * suck))
            }
            let point = queueFlightPoint(progress: t, start: destination, end: end)
            let appear = min(t / 0.12, 1)
            let scale = (0.7 + 0.3 * appear) * (1 - 0.62 * t)
            for layer in 0..<count {
                let dx: CGFloat = count > 1 ? CGFloat(layer - 1) * 3 : 0
                let dy: CGFloat = count > 1 ? CGFloat(1 - layer) * 2 : 0
                frames.append(QueueFlightLayerFrame(center: CGPoint(x: point.x + dx * scale, y: point.y + dy * scale),
                    scale: scale, rotation: count > 1 ? CGFloat(layer - 1) * 9 : 0,
                    alpha: appear * (t > 0.94 ? (1 - t) / 0.06 : 1)))
            }
            return frames
        }
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
    if x == 0 || x == 1 { return x }
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

/// Collection cards, their action buttons and member photos have independent
/// geometry even when the first member shares the collection's display image.
enum PhotoListCellID: Hashable {
    case photo(UInt32)
    case burst(String)
    case burstEnqueue(String)
}

func visiblePhotoListCellBounds(_ id: PhotoListCellID, bounds: [PhotoListCellID: CGRect],
                                viewport: CGRect) -> CGRect? {
    guard let frame = bounds[id], !frame.isEmpty, !frame.isInfinite, !frame.isNull,
          frame.intersects(viewport) else { return nil }
    return frame
}

func photoPreviewAnchorBounds(_ id: PhotoListCellID, bounds: [PhotoListCellID: CGRect],
                              viewport: CGRect) -> PhotoPreviewAnchorBounds? {
    guard let image = bounds[id] else { return nil }
    return PhotoPreviewAnchorBounds.clipped(image: image, to: viewport)
}

/// Flight admission is independent of transfer admission: repeated exports
/// still enqueue, but missing/offscreen or already-flying sources hold no count.
func admittedPhotoListFlightSource(_ source: CGRect?, viewport: CGRect, activeSources: [CGRect]) -> CGRect? {
    guard let source, !source.isEmpty, !source.isNull, !source.isInfinite,
          source.intersects(viewport), !activeSources.contains(source) else { return nil }
    return source
}

struct PhotoListFlightAdmissions {
    struct Admission {
        let id: UUID
        let source: CGRect
        let count: Int
    }
    private var active: [UUID: Admission] = [:]
    var activeIDs: [UUID] { Array(active.keys) }
    var heldCount: Int { active.values.reduce(0) { $0 + $1.count } }

    mutating func admit(source: CGRect?, viewport: CGRect, count: Int) -> Admission? {
        guard count > 0, let source = admittedPhotoListFlightSource(source, viewport: viewport,
                                    activeSources: active.values.map(\.source)) else { return nil }
        let admission = Admission(id: UUID(), source: source, count: count)
        active[admission.id] = admission
        return admission
    }

    /// Completion and cancellation consume the same identity exactly once.
    /// A late callback cannot release a newer flight from the same source.
    mutating func finish(_ id: UUID) -> Int? { active.removeValue(forKey: id)?.count }
}

struct PhotoListCellBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [PhotoListCellID: CGRect] = [:]
    static func reduce(value: inout [PhotoListCellID: CGRect], nextValue: () -> [PhotoListCellID: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct PhotoListSectionEnqueueBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

struct PhotoListQueueTargetPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// Only disconnected STA can request reconnection. USB, connected STA and AP
/// remain status-only; no system wireless-settings jump is offered.
struct CameraSignalControl: View {
    let isUSB: Bool
    let wirelessMode: WirelessMode?
    let connected: Bool
    var height: CGFloat = 36
    var onRetrySTA: () -> Void = {}

    private var canRetrySTA: Bool { !isUSB && wirelessMode == .sta && !connected }

    private var labelKey: String {
        if canRetrySTA { return "sta_signal_disconnected_reconnect" }
        if !connected { return "camera_not_connected" }
        return isUSB ? "connection_usb" : "camera_session_notification_title"
    }

    var body: some View {
        Button { if canRetrySTA { onRetrySTA() } } label: {
            PhotoListSignalIcon(isUSB: isUSB, wirelessMode: wirelessMode, connected: connected)
                .frame(width: photoListCompactButtonWidth, height: height)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22, disabledAlpha: 1))
        .disabled(!canRetrySTA)
        .allowsHitTesting(canRetrySTA)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalized.resource(labelKey))
        .accessibilityIdentifier("photo-list-signal")
        .accessibilityRemoveTraits(canRetrySTA ? [] : .isButton)
        .modifier(DisconnectedSignalBreath(connected: connected))
        // Android scales inside the signal pill's layout slot. Constrain the
        // outer animation host too: its UIView otherwise accepts the HStack's
        // remaining width when disconnected and pushes the filter outwards.
        .frame(width: photoListCompactButtonWidth, height: height)
    }
}

/// SignalPill family: USB keeps its dedicated mark, STA shows topology state,
/// and AP uses a static four-bar connected mark. iOS intentionally does not
/// request the restricted Access Wi-Fi Information capability.
struct PhotoListSignalIcon: View {
    let isUSB: Bool
    let wirelessMode: WirelessMode?
    var connected = true

    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isUSB {
            ClassicUSBIcon(tint: connected ? ZTransferColors.accentBlue : ZTransferColors.statusError)
                .frame(width: 18, height: 18)
        } else if wirelessMode == .sta {
            let tint = connected ? ZTransferColors.accentBlue : ZTransferColors.statusError
            STASignalIcon(connected: connected, tint: tint)
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

/// Android's original 24-unit Material Checklist path, displayed at 22pt.
private struct PhotoListQueueIcon: View {
    var tint: Color = ZTransferColors.statusConnected
    var body: some View {
        QueueTopIcon(kind: .checklist).fill(tint)
            .accessibilityLabel(AppLocalized.resource("cd_transfer"))
    }
}

private func formatDateHeader(_ raw: String) -> String {
    guard raw.count == 8,
          raw.allSatisfy(\.isNumber) else { return raw }
    let chars = Array(raw)
    return "\(chars[0])\(chars[1])\(chars[2])\(chars[3])-\(chars[4])\(chars[5])-\(chars[6])\(chars[7])"
}

/// Only the empty-state sentence depends on rating progress. A loader with no
/// concrete star must never invalidate the list's grid or preview input.
struct PhotoListRatingEmptyState: View {
    @ObservedObject var progress: PhotoRatingProgress
    let filter: PhotoFilterState
    let protectionAvailable: Bool
    let onClearFilter: () -> Void

    var body: some View {
        PhotoListEmptyState(filterActive: filter.isActive(protectionAvailable: protectionAvailable),
                            showNoMatchMessage: filter.showsNoMatchMessage(ratingLoading: progress.snapshot.loading),
                            onClearFilter: onClearFilter)
    }
}

private struct PhotoListEmptyState: View {
    let filterActive: Bool
    let showNoMatchMessage: Bool
    let onClearFilter: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if filterActive {
                    // Android emptyFilter uses the same outlined FilterMark
                    // as the toolbar, at 44dp; never substitute a system icon.
                    PhotoListFilterIcon(active: false, color: ZTransferColors.secondaryText)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 48, weight: .regular))
                }
            }
            .foregroundStyle(ZTransferColors.secondaryText)
            .modifier(PhotoListEmptyPulse())
            if !filterActive || showNoMatchMessage {
                Text(AppLocalized.resource(filterActive ? "no_photos_match_filter" : "no_photos_on_camera"))
                    .zTransferText(size: ZTransferMetrics.body)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            // USB readiness is checked before first entry. A successful empty
            // album must not also suggest that its powered-on camera is off.
            if filterActive {
                Button(action: onClearFilter) {
                    Text(AppLocalized.resource("clear_filters"))
                        .zTransferTypography(.labelLarge, weight: .medium)
                        .foregroundStyle(ZTransferColors.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        // GlassButton defaults: size the label before its
                        // material so every locale fits inside the same face.
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 20))
            }
        }
    }
}

private struct PhotoListScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum PhotoGridEntry: Identifiable, Equatable {
    case photo(CameraFile)
    case burst(BurstPhotoGroup)
    var id: String {
        switch self { case let .photo(file): return "photo_\(file.id)"; case let .burst(group): return "burst_\(group.id)" }
    }
    var cellID: PhotoListCellID {
        switch self { case let .photo(file): return .photo(file.id); case let .burst(group): return .burst(group.id) }
    }
    var firstFile: CameraFile {
        switch self { case let .photo(file): return file; case let .burst(group): return group.files[0] }
    }
    var isPhoto: Bool {
        if case .photo = self { return true }
        return false
    }
}

func photoGridEntries(_ files: [CameraFile], burstIDByFile: [UInt32: String], collapse: Bool = true,
                              expandedIDs: Set<String> = []) -> [PhotoGridEntry] {
    guard collapse else { return files.map(PhotoGridEntry.photo) }
    let visibleGroups = visiblePhotoBurstMembers(files: files, burstIDs: burstIDByFile)
    var entries: [PhotoGridEntry] = []
    entries.reserveCapacity(files.count)
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


@MainActor
private final class QueuePillContentClock: ObservableObject {
    @Published private(set) var motion: QueuePillContentMotion
    private var link: CADisplayLink?
    init(_ initial: QueuePillPresentation) { motion = .init(initial) }

    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: QueuePillContentClock?
        init(_ owner: QueuePillContentClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(link)
        }
    }

    func update(_ next: QueuePillPresentation) {
        motion.update(next)
        guard motion.isRunning, link == nil else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    private func frame(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000))
        if !motion.isRunning { stop() }
    }
    func mount(_ next: QueuePillPresentation) { stop(); motion = .init(next) }
    func stop() { link?.invalidate(); link = nil }
}

struct QueuePillContentTransition<Surface: View, Content: View>: View {
    let presentation: QueuePillPresentation
    let content: (QueuePillPresentation) -> Content
    let surface: (QueuePillContentMotion) -> Surface
    @StateObject private var clock: QueuePillContentClock

    init(presentation: QueuePillPresentation,
         @ViewBuilder surface: @escaping (QueuePillContentMotion) -> Surface,
         @ViewBuilder content: @escaping (QueuePillPresentation) -> Content) {
        self.presentation = presentation
        self.surface = surface
        self.content = content
        _clock = StateObject(wrappedValue: QueuePillContentClock(presentation))
    }

    var body: some View {
        // The proposed animated width belongs to the surface. Retained,
        // unbounded text must not impose its old minimum width on that surface
        // (a ZStack did so until the outgoing label was removed at 160ms).
        surface(clock.motion).overlay(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                ForEach(clock.motion.layers) { layer in
                    content(layer.id == presentation.mode ? presentation : layer.presentation)
                        // Android wrapContentWidth(End, unbounded = true): the
                        // viewport must not squeeze the outgoing text as it shrinks.
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, layer.id == .icon ? 0 : 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .opacity(Double(layer.fade.alpha.value))
                        .accessibilityHidden(layer.id != presentation.mode)
                }
            }
        }
        .onAppear { clock.mount(presentation) }
        .onChange(of: presentation) { clock.update($0) }
        .onDisappear { clock.stop() }
    }
}


/// The fill/material follows the same retained mode transition as its text.
/// A boolean switch previously removed the full blue fill on the first
/// Done→icon frame, before either the width spring or label fade had advanced.
private struct QueuePillSurface: View {
    let motion: QueuePillContentMotion
    let skin: ZTransferButtonSkin
    let progress: AndroidAnimatedOpacity
    let taskID: UUID?
    let animate: Bool

    var body: some View {
        let appearance = motion.surface
        ZStack {
            if skin == .liquidGlass {
                // One native glass instance survives all states and width frames.
                ZTransferButtonMaterialSurface(skin: skin, cornerRadius: 22, textureSeed: 0x2A71E001)
            } else {
                ZTransferButtonMaterialSurface(skin: skin, cornerRadius: 22, textureSeed: 0x2A71E001)
                    .opacity(appearance.iconAlpha)
                ZTransferGlassSurface(cornerRadius: 22, kind: .button)
                    .opacity(1 - appearance.iconAlpha)
            }
            if appearance.hasContent, let taskID, animate {
                QueuePillDownloadFill(progress: progress, taskID: taskID)
                    .opacity(appearance.fillAlpha)
            }
            if skin != .liquidGlass {
                Capsule().strokeBorder(.white.opacity(0.14 * (1 - appearance.iconAlpha)), lineWidth: 0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}


private struct QueuePillDownloadFill: View {
    @ObservedObject var progress: AndroidAnimatedOpacity
    let taskID: UUID
    var body: some View {
        LiquidTransferProgressSurface(progress: Double(progress.value),
            seed: taskID.uuidString, isCapsule: true, waveEligible: true)
#if DEBUG
            .preference(key: SmoothTransferProgressObservationKey.self,
                value: .init(key: taskID.uuidString, value: progress.value))
#endif
    }
}

@MainActor
final class QueuePillWidthClock: ObservableObject {
    @Published private(set) var motion = QueueTopPillWidthMotion()
    private var link: CADisplayLink?

    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: QueuePillWidthClock?
        init(_ owner: QueuePillWidthClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(link)
        }
    }

    func update(width: CGFloat, scale: CGFloat) {
        motion.update(width: width, scale: scale)
        guard motion.isRunning, link == nil else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    private func frame(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000))
        if !motion.isRunning { stop() }
    }

    private func stop() { link?.invalidate(); link = nil }
    func reset() { stop(); motion = .init() }
}

/// Only the occupancy layout follows the width spring. The button, material,
/// retained content transitions and hidden measurement stay outside its body.
struct QueuePillAnimatedSize<Content: View>: View {
    @ObservedObject var clock: QueuePillWidthClock
    var visible: Bool? = nil
    var naturalWidth: CGFloat = 0
    var onRetained: (Bool) -> Void = { _ in }
    @State private var visibilityTransition = false
    @ViewBuilder var content: Content
    var body: some View {
        let width = clock.motion.width ?? (visible == false ? 0 : naturalWidth)
        let retained = visible != false || width > 0
        let feather = queuePillVisibilityFeather(width: width, naturalWidth: naturalWidth,
                                                transitioning: visibilityTransition)
        QueuePillSizingLayout(displayedWidth: clock.motion.width, height: photoListTopControlsHeight) { content }
            .opacity(visible == nil ? 1 : min(1, max(0, width / 8)))
            .modifier(QueuePillEdgeMask(amount: feather, width: width))
            .onAppear { onRetained(retained) }
            .onChange(of: retained) { onRetained($0) }
            .onChange(of: visible) { _ in visibilityTransition = true }
            .onChange(of: clock.motion.isRunning) { if !$0 { visibilityTransition = false } }
    }
}

private struct QueuePillEdgeMask: ViewModifier {
    let amount: Double
    let width: CGFloat
    func body(content: Content) -> some View {
        // Mask the rightmost 24pt including 16pt of shadow spill. No painted
        // overlay, no scale/fade transition independent from the width spring.
        content.mask {
            HStack(spacing: 0) {
                Color.white
                LinearGradient(colors: [.white, .white.opacity(1 - amount)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(24, max(0, width)))
                Color.white.opacity(1 - amount).frame(width: 16)
            }.padding(-16)
        }
    }
}

private struct LiveQueuePill: View {
    let snapshot: TransferQueueSnapshot
    @ObservedObject var progressModel: TransferQueueProgressViewModel
    let visible: Bool
    let heldCount: Int
    let onClick: () -> Void
    private let taskSummary: QueuePillTaskSummary

    init(snapshot: TransferQueueSnapshot, progressModel: TransferQueueProgressViewModel,
         heldCount: Int, visible: Bool, onClick: @escaping () -> Void) {
        self.visible = visible
        self.snapshot = snapshot; self.progressModel = progressModel
        self.heldCount = heldCount; self.onClick = onClick
        // Structural snapshots change the summary; 200ms speed samples don't.
        taskSummary = .init(items: snapshot.items)
    }

    var body: some View {
        QueuePill(
            snapshot: snapshot,
            activeProgress: progressModel.activeProgress,
            heldCount: heldCount,
            visible: visible,
            taskSummary: taskSummary,
            onClick: onClick
        )
    }
}

struct QueuePill: View {
    let snapshot: TransferQueueSnapshot
    let activeProgress: TransferActiveProgress?
    let heldCount: Int
    let visible: Bool
    let onClick: () -> Void

    private let taskSummary: QueuePillTaskSummary

    init(snapshot: TransferQueueSnapshot, activeProgress: TransferActiveProgress?,
         heldCount: Int, visible: Bool = true, taskSummary: QueuePillTaskSummary? = nil, onClick: @escaping () -> Void = {}) {
        self.onClick = onClick
        self.snapshot = snapshot
        self.activeProgress = activeProgress
        self.heldCount = heldCount
        self.visible = visible
        let summary = taskSummary ?? QueuePillTaskSummary(items: snapshot.items)
        self.taskSummary = summary
        _downloadDisplay = StateObject(wrappedValue: .init(initialTask: summary.activeDownload))
    }

    @State private var showDoneLabel = false
    @State private var completionTracker = QueueCompletionTracker()
    @State private var consumedCompletion: UInt64 = 0
    @State private var countingVisible = false
    @State private var widthRetained = true
    @StateObject private var downloadDisplay: QueueDownloadDisplayModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var doneTask: Task<Void, Never>?
    @State private var widthMeasurement = QueuePillWidthMeasurement()
    @State private var widthClock = QueuePillWidthClock()
    @Environment(\.displayScale) private var displayScale
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var downloadRemaining: Int { taskSummary.downloadRemaining }
    private var generationCount: Int { taskSummary.generationRemaining }
    private var activeItem: TransferQueueItem? { taskSummary.activeDownload }
    private var activeSpeed: Int64 {
        guard snapshot.isTransferring else { return 0 }
        return activeProgress?.retainedBytesPerSecond ?? activeItem?.bytesPerSecond ?? 0
    }
    private var displayedSpeed: Int64? { activeSpeed > 0 ? activeSpeed : nil }
    private var activeSpeedText: String? { displayedSpeed.map(transferSpeedText) }
    private var completionObservation: QueueCompletionTracker.Observation { completionTracker.observe(snapshot.items) }
    private var completionPending: Bool {
        let observation = completionObservation
        return consumedCompletion != observation.revision && observation.update.feedback?.showDone == true
    }
    private var animateContents: Bool { (visible || widthRetained) && scenePhase == .active }
    private var finishingDownload: Bool {
        downloadDisplay.completing || queueDownloadCompletedTask(downloadDisplay.task?.id,
            active: activeItem, tasks: snapshot.items) != nil
    }
    private struct DownloadInput: Equatable {
        let active: TransferQueueItem?
        let progress: TransferActiveProgress?
        let tasks: [TransferQueueItem]
        let animate: Bool
    }
    private var downloadInput: DownloadInput {
        .init(active: activeItem, progress: activeProgress, tasks: snapshot.items, animate: animateContents)
    }
    private var displayRemainingCount: Int { taskSummary.displayRemaining(heldCount: heldCount) }
    private var allDone: Bool { taskSummary.allDone }
    private var paused: Bool { !snapshot.isTransferring && downloadRemaining > 0 }
    private var hasWorkingTask: Bool { taskSummary.hasActive }
    private struct CountVisibilityInput: Equatable {
        let hasRemaining: Bool
        let hasWorkingTask: Bool
        let paused: Bool
    }
    private var countVisibilityInput: CountVisibilityInput {
        .init(hasRemaining: displayRemainingCount > 0,
              hasWorkingTask: hasWorkingTask, paused: paused)
    }
    private var doneVisible: Bool { showDoneLabel || completionPending }
    private var allRemainingTasksAreInFlight: Bool {
        taskSummary.allDownloadsAreInFlight(heldCount: heldCount)
    }
    private var collapsedToIcon: Bool {
        allRemainingTasksAreInFlight ||
            (!finishingDownload && !paused && ((allDone && !doneVisible) || (!allDone && !countingVisible && !hasWorkingTask)))
    }
    private var visualMode: QueuePillVisualMode {
        if collapsedToIcon { return .icon }
        if allDone { return .done }
        if paused { return .paused }
        if downloadRemaining == 0, generationCount > 0 { return .generating }
        return .counting
    }
    private var presentation: QueuePillPresentation {
        .init(mode: visualMode,
              count: visualMode == .generating ? generationCount : displayRemainingCount,
              speed: visualMode == .counting ? displayedSpeed : nil, showDone: doneVisible)
    }
    private var widthKey: QueuePillWidthKey {
        .init(mode: visualMode, speedText: activeSpeedText,
              count: visualMode == .generating ? generationCount : displayRemainingCount)
    }
    private var targetWidth: CGFloat { visible ? naturalWidth : 0 }
    private var naturalWidth: CGFloat {
        if visualMode == .done && !doneVisible { return 0 }
        guard visualMode != .icon else { return 40 }
        // Hold the previous measured width for the one layout pass needed to
        // measure new content. This prevents text appearing outside a width
        // that is still springing from the icon state.
        return widthMeasurement.width
    }

    var body: some View {
        QueuePillAnimatedSize(clock: widthClock, visible: visible, naturalWidth: naturalWidth,
                              onRetained: { widthRetained = $0 }) {
            // Keep one button and one transition owner across icon/count/
            // paused/generating/Done. Branching the whole button discarded
            // outgoing layers and restarted child clocks on mode changes.
            Button(action: onClick) {
                QueuePillContentTransition(presentation: presentation) { motion in
                    QueuePillSurface(motion: motion, skin: .init(storedValue: skinPreset),
                        progress: downloadDisplay.progress, taskID: downloadDisplay.task?.id,
                        animate: animateContents)
                } content: { displayed in
                    pillContent(for: displayed)
                }
                .frame(height: photoListTopControlsHeight, alignment: .trailing)
                .compositingGroup()
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .disabled(!visible)
            .accessibilityHidden(!visible)
            .buttonStyle(QueuePillButtonStyle())
            .frame(height: photoListTopControlsHeight)

            measurementContent(for: visualMode)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, visualMode == .icon ? 0 : 16)
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: QueuePillMeasuredWidthPreferenceKey.self,
                            value: [widthKey: proxy.size.width]
                        )
                    }
                }
                .id(widthKey)
        }
        .onPreferenceChange(QueuePillMeasuredWidthPreferenceKey.self) { widths in
            // There is exactly one hidden measurement child. Consume its key
            // together with its width, never a preceding View's captured key
            // (Done -> counting could otherwise keep Done's 68pt viewport).
            for (key, width) in widths {
                widthMeasurement.measure(width, key: key)
            }
        }
        .onChange(of: targetWidth) { width in
            widthClock.update(width: width, scale: displayScale)
        }
        .onChange(of: displayScale) { scale in
            widthClock.update(width: targetWidth, scale: scale)
        }
        .task(id: countVisibilityInput) {
            // Android keys the grace period by remaining > 0, not the count.
            let input = countVisibilityInput
            if input.paused || input.hasWorkingTask {
                countingVisible = true
            } else if input.hasRemaining {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                countingVisible = true
            } else {
                countingVisible = false
            }
        }
        .onChange(of: downloadInput) { updateDownload($0) }
        .onChange(of: completionObservation) { consumeCompletion($0) }
        .onAppear {
            consumeCompletion(completionObservation)
            widthClock.update(width: targetWidth, scale: displayScale)
            updateDownload(downloadInput)
        }
        .onDisappear {
            doneTask?.cancel()
            widthClock.reset()
            downloadDisplay.stop()
        }
        .background {
#if DEBUG
            Color.clear.preference(key: QueuePillObservationKey.self,
                value: QueuePillObservation(countingVisible: countingVisible,
                                           count: displayRemainingCount, mode: visualMode,
                                           completionFill: finishingDownload))
#endif
        }
    }

    private func updateDownload(_ input: DownloadInput) {
        downloadDisplay.update(active: input.active, progress: input.progress,
                               tasks: input.tasks, animate: input.animate)
    }
    private func consumeCompletion(_ observation: QueueCompletionTracker.Observation) {
        guard consumedCompletion != observation.revision else { return }
        consumedCompletion = observation.revision
        if !observation.update.state.unresolvedTaskIDs.isEmpty {
            doneTask?.cancel(); showDoneLabel = false
        }
        guard let feedback = observation.update.feedback else { return }
        doneTask?.cancel(); showDoneLabel = feedback.showDone
        if feedback.celebrate { ZTransferHaptics.shared.play(.transferComplete) }
        if feedback.showDone {
            doneTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(1800)) } catch { return }
                showDoneLabel = false
            }
        }
    }

    @ViewBuilder
    private func pillContent(for displayed: QueuePillPresentation) -> some View {
        switch displayed.mode {
        case .icon:
            PhotoListQueueIcon(tint: zTransferMaterialContentColor(
                skin: .init(storedValue: skinPreset),
                scheme: colorScheme,
                fallback: ZTransferColors.statusConnected
            ))
                .frame(width: 22, height: 22)
                .frame(width: 40, height: photoListTopControlsHeight)
        case .done:
            if displayed.showDone { Text("Done")
                .monospacedDigit()
                .zTransferTypography(.labelLarge, weight: .bold)
                .foregroundStyle(ZTransferColors.statusConnected)
                .lineLimit(1) }
        case .paused:
            QueuePillRollingCount(count: displayed.count, animate: visible && scenePhase == .active)
        case .generating:
            HStack(alignment: .center, spacing: 6) {
                generationIcon
                QueuePillRollingCount(count: displayed.count, animate: visible && scenePhase == .active)
            }
        case .counting:
            HStack(alignment: .center, spacing: 8) {
                if let speed = displayed.speed {
                    QueueAnimatedValue(text: transferSpeedText(speed), value: speed, style: .labelMedium,
                        color: ZTransferColors.accentBlue, animate: visible && scenePhase == .active)
                }
                QueuePillRollingCount(count: displayed.count, animate: visible && scenePhase == .active)
            }
        }
    }

    @ViewBuilder
    private func measurementContent(for mode: QueuePillVisualMode) -> some View {
        switch mode {
        case .icon:
            Color.clear.frame(width: 40, height: photoListTopControlsHeight)
        case .done:
            Text("Done").monospacedDigit().zTransferTypography(.labelLarge, weight: .bold).lineLimit(1)
        case .paused:
            measurementCount(displayRemainingCount)
        case .generating:
            HStack(spacing: 6) {
                generationIcon
                measurementCount(generationCount)
            }
        case .counting:
            HStack(spacing: activeSpeedText == nil ? 0 : 8) {
                if let activeSpeedText {
                    Text(activeSpeedText)
                        .zTransferTypography(.labelMedium, weight: .bold)
                        .monospacedDigit().lineLimit(1)
                }
                measurementCount(displayRemainingCount)
            }
        }
    }

    // FileListScreen.QueuePill GENERATING: Material AutoAwesome, 16dp,
    // accentPurple; the localized text is an accessibility description only.
    private var generationIcon: some View {
        QueueBadgeIcon(state: .generating)
            .fill(ZTransferColors.accentPurple)
            .frame(width: 16, height: 16)
            .accessibilityLabel(AppLocalized.resource("queue_pill_generating"))
            .accessibilityIdentifier("queue-pill-generation-icon")
    }

    private func measurementCount(_ value: Int) -> some View {
        Text("\(value)")
            .zTransferTypography(.labelLarge, weight: .bold)
            .monospacedDigit()
            .lineLimit(1)
    }

}

/// The first child draws the capsule; the hidden second child supplies its
/// unbounded natural width. First layout therefore needs no guessed width.
/// Later layouts propose only the animated viewport to the visible surface.
struct QueuePillSizingLayout: Layout {
    let displayedWidth: CGFloat?
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let natural = subviews[1].sizeThatFits(.unspecified)
        let width = displayedWidth ?? natural.width
        let available = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? width
        return CGSize(width: min(width, available), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                          proposal: ProposedViewSize(bounds.size))
        let natural = subviews[1].sizeThatFits(.unspecified)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(natural))
    }
}

private struct QueuePillMeasuredWidthPreferenceKey: PreferenceKey {
    static let defaultValue: [QueuePillWidthKey: CGFloat] = [:]
    static func reduce(
        value: inout [QueuePillWidthKey: CGFloat],
        nextValue: () -> [QueuePillWidthKey: CGFloat]
    ) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

@MainActor
final class QueuePillPressClock: ObservableObject {
    @Published private(set) var scale: Float = 1
    private var animation = ZTransferScalarAnimation(value: 1)
    private var link: CADisplayLink?

    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: QueuePillPressClock?
        init(_ owner: QueuePillPressClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(link)
        }
    }

    func update(pressed: Bool, nativeGlass: Bool, pressedScale: Float = 0.95) {
        guard !nativeGlass else { reset(); return }
        animation.retarget(pressed ? pressedScale : 1,
                           using: pressed ? .tween(milliseconds: 80) : .bouncy)
        guard animation.isRunning, link == nil else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    private func frame(_ link: CADisplayLink) {
        animation.advance(frameNanos: Int64(link.timestamp * 1_000_000_000))
        scale = animation.value
        if !animation.isRunning { stop() }
    }

    private func stop() { link?.invalidate(); link = nil }
    func reset() {
        stop()
        animation.reset(to: 1)
        scale = 1
    }
}

struct QueuePillPressEffect: ViewModifier {
    let pressed: Bool
    let nativeGlass: Bool
    var pressedScale: Float = 0.95
    @StateObject private var clock = QueuePillPressClock()

    func body(content: Content) -> some View {
        content
            // Android graphicsLayer's default transformOrigin is the center.
            .scaleEffect(CGFloat(clock.scale))
            .onAppear { clock.update(pressed: pressed, nativeGlass: nativeGlass, pressedScale: pressedScale) }
            .onChange(of: pressed) { clock.update(pressed: $0, nativeGlass: nativeGlass, pressedScale: pressedScale) }
            .onChange(of: nativeGlass) { clock.update(pressed: pressed, nativeGlass: $0, pressedScale: pressedScale) }
            .onDisappear { clock.reset() }
    }
}

private struct QueuePillButtonStyle: ButtonStyle {
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(QueuePillPressEffect(
            pressed: configuration.isPressed,
            nativeGlass: ZTransferButtonSkin(storedValue: skinPreset) == .liquidGlass
        ))
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
    let session: CameraSession?
    var file: CameraFile?
    var allowRemoteThumbnail = true
    var loadEnabled = true
    var transfersBusy = false
    var transferred: Bool = false
    var inBurst: Bool = false
    var showsCornerBadges: Bool = true
    var queueTask: TransferQueueItem? = nil
    var progressModel: TransferQueueProgressViewModel? = nil
    var cornerRadius: CGFloat = 8
    var showsPlaceholderIcon = true

    init(
        session: CameraSession?,
        file: CameraFile? = nil,
        allowRemoteThumbnail: Bool = true,
        loadEnabled: Bool = true,
        transfersBusy: Bool = false,
        transferred: Bool = false,
        inBurst: Bool = false,
        showsCornerBadges: Bool = true,
        queueTask: TransferQueueItem? = nil,
        progressModel: TransferQueueProgressViewModel? = nil,
        cornerRadius: CGFloat = 8,
        showsPlaceholderIcon: Bool = true
    ) {
        self.session = session
        self.file = file
        self.allowRemoteThumbnail = allowRemoteThumbnail
        self.loadEnabled = loadEnabled
        self.transfersBusy = transfersBusy
        self.transferred = transferred
        self.inBurst = inBurst
        self.showsCornerBadges = showsCornerBadges
        self.queueTask = queueTask
        self.progressModel = progressModel
        self.cornerRadius = cornerRadius
        self.showsPlaceholderIcon = showsPlaceholderIcon
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
            PhotoThumbnailImage(session: session, file: file, loadEnabled: loadEnabled,
                allowRemote: allowRemoteThumbnail, transfersBusy: transfersBusy,
                cornerRadius: cornerRadius, showsPlaceholderIcon: showsPlaceholderIcon,
                stacked: !showsCornerBadges, expandedBurst: inBurst)
                .frame(width: geometry.size.width, height: geometry.size.height)
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
        .modifier(PhotoThumbnailOverlayClip(enabled: showsCornerBadges, radius: cornerRadius))
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

private struct PhotoThumbnailOverlayClip: ViewModifier {
    let enabled: Bool
    let radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.clipShape(RoundedRectangle(cornerRadius: radius)) }
        else { content }
    }
}

private struct BurstThumbnailView: View {
    let session: CameraSession?
    let group: BurstPhotoGroup
    var allowRemoteThumbnails = true
    var loadEnabled = true
    var transfersBusy = false
    var transferred: Bool = false
    var expanded = false
    var onExpand: () -> Void = {}
    var onEnqueue: () -> Void = {}
    var onPreview: () -> Void = {}
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let cardSide = side * 0.86
            ZStack {
                PhotoThumbnailStackTransition(files: group.files) { renderedFiles in
                    ZStack {
                        ForEach(Array(renderedFiles.enumerated().reversed()), id: \.element.id) { item in
                            let placement = PhotoThumbnailStackCard(frontIndex: item.offset, visibleCount: renderedFiles.count)
                            CameraThumbnailView(session: session, file: item.element,
                                                allowRemoteThumbnail: allowRemoteThumbnails,
                                                loadEnabled: loadEnabled, transfersBusy: transfersBusy,
                                                showsCornerBadges: false, cornerRadius: 10,
                                                showsPlaceholderIcon: item.offset == 0)
                                .accessibilityIdentifier("burst-image-\(item.element.id)")
                                .frame(width: cardSide, height: cardSide)
                                .rotationEffect(.degrees(placement.rotation))
                                .offset(x: placement.x, y: placement.y)
                        }
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .clear, location: 0.55),
                                               .init(color: .black.opacity(0.42), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(width: cardSide, height: cardSide)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .offset(y: 1)
                            .allowsHitTesting(false)
                    }
                }
                // Match BurstCollectionCell: image-only long press below the
                // action buttons. Holding either button must not open preview.
                Color.clear
                    .frame(width: cardSide, height: cardSide)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: photoPreviewLongPressDuration,
                                        maximumDistance: 12, perform: onPreview)
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
                            .accessibilityIdentifier("enqueue-burst-\(group.id)")
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: PhotoListCellBoundsPreferenceKey.self,
                                        value: [.burstEnqueue(group.id): proxy.frame(in: .global)])
                                }
                            }
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

#if DEBUG
/// Bounded, read-only rating/protection diagnostics. This mirrors Android's
/// debug panel and is absent from Release builds.
private struct DebugPhotoProtectionPanel: View {
    let isSTA: Bool
    let files: [CameraFile]
    let session: CameraSession?
    @State private var shareTask: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var sharing = false
    @State private var sharePresented = false
    @State private var notice = "诊断日志已复制"
    @State private var open = false
    @State private var busy = false
    @State private var diagnosticLines: [String] = []
    @State private var copyNotice = false
    @State private var copyNoticeID = UUID()

    var body: some View {
        GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    if open {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { open = false }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("诊断日志").font(.headline)
                                    Text("遇到问题后分享日志")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { shareReport() } label: { Image(systemName: "square.and.arrow.up") }
                                    .disabled(sharing)
                                    .accessibilityLabel("分享 Debug 日志文件")
                                Button {
                                    UIPasteboard.general.string = diagnosticReport()
                                    showNotice("诊断日志已复制")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .accessibilityLabel("复制 Debug 日志")
                                Button {
                                    PhotoRatingDiagnostics.clear(); STAConnectionDiagnostics.clear(); refreshDiagnosticLines()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("清空 Debug 日志")
                                Button { open = false } label: {
                                    Image(systemName: "xmark").frame(width: 32, height: 32)
                                }
                                .buttonStyle(ZTransferGlassButtonStyle.iconControl(cornerRadius: 12))
                                .accessibilityLabel("关闭")
                            }
                            HStack(spacing: 8) {
                                if !isSTA {
                                    Button(busy ? "RAW 探测中…" : "探测 RAW 评级") { runRawProbe() }
                                        .disabled(busy)
                                } else {
                                    Button(busy ? "保护头探测中…" : "探测保护头") { runHeaderProbe() }
                                        .disabled(busy)
                                    Button(busy ? "属性探测中…" : "探测保护属性") { runPropertyProbe() }
                                        .disabled(busy)
                                }
                            }
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(diagnosticLines.indices, id: \.self) { index in
                                        Text(diagnosticLines[index])
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(diagnosticColor(for: diagnosticLines[index]))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .frame(maxHeight: .infinity)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: proxy.size.height * 0.82)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2)))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) {
                            if copyNotice {
                                Text(notice)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                                    .transition(.opacity)
                                    .padding(.bottom, 18)
                            }
                        }
                    } else {
                        Button {
                            refreshDiagnosticLines()
                            open = true
                        } label: {
                            Label("诊断日志", systemImage: "timer")
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            }
            .sheet(isPresented: $sharePresented) { if let shareURL { FileShareSheet(url: shareURL) } }
            .onChange(of: open) { visible in if !visible { shareTask?.cancel() } }
            .onDisappear { shareTask?.cancel() }
    }

    private func showNotice(_ text: String) {
        notice = text
        let id = UUID(); copyNoticeID = id; copyNotice = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copyNoticeID == id { copyNotice = false }
        }
    }
    private func diagnosticReport() -> String {
        STAConnectionDiagnostics.snapshot() + "\n\n" + PhotoRatingDiagnostics.snapshot()
    }
    private func shareReport() {
        guard !sharing else { return }
        sharing = true
        let report = diagnosticReport()
        shareTask = Task { @MainActor in
            defer { sharing = false }
            do {
                shareURL = try await Task.detached {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picture_control_reports", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent("Shared-PhotoDiagnostics-\(UUID().uuidString).txt")
                    try report.write(to: file, atomically: true, encoding: .utf8)
                    return file
                }.value
                try Task.checkCancellation()
                sharePresented = true
            } catch is CancellationError {
                return
            } catch {
                showNotice("分享失败，请重试")
            }
        }
    }

    private func refreshDiagnosticLines() {
        // Android remembers these rows per open/logVersion. Busy/progress or
        // copy-notice changes must not rescan the report or reset its scroll.
        let next = diagnosticReport().split(separator: "\n").map(String.init)
        if diagnosticLines != next { diagnosticLines = next }
    }

    private func diagnosticColor(for line: String) -> Color {
        if line.localizedCaseInsensitiveContains("failed") || line.localizedCaseInsensitiveContains("error") {
            return .orange
        }
        if line.localizedCaseInsensitiveContains("saved") {
            return .green
        }
        return .white.opacity(0.82)
    }

    private func runHeaderProbe() {
        guard !busy, let session else { return }
        busy = true
        let previous = PhotoRatingDiagnostics.beginProbe(keepExisting: true)
        Task {
            await session.probeProtectionHeaders(files: files)
            PhotoRatingDiagnostics.restore(previous, preserveEntries: true)
            await MainActor.run { busy = false; refreshDiagnosticLines() }
        }
    }

    private func runRawProbe() {
        guard !busy, let session,
              let raw = files.first(where: { $0.fileExtension == ".nef" || $0.fileExtension == ".nrw" }) else { return }
        busy = true
        let previous = PhotoRatingDiagnostics.beginProbe()
        Task {
            await session.probeRawRating(file: raw)
            PhotoRatingDiagnostics.restore(previous, preserveEntries: true)
            await MainActor.run { busy = false; refreshDiagnosticLines() }
        }
    }

    private func runPropertyProbe() {
        guard !busy, let session else { return }
        busy = true
        let previous = PhotoRatingDiagnostics.beginProbe(keepExisting: true)
        Task {
            await session.probeProtectionProperties(files: files)
            PhotoRatingDiagnostics.restore(previous, preserveEntries: true)
            await MainActor.run { busy = false; refreshDiagnosticLines() }
        }
    }
}
#else
private struct DebugPhotoProtectionPanel: View {
    init(isSTA: Bool, files: [CameraFile], session: CameraSession?) {}
    var body: some View { EmptyView() }
}
#endif

#if DEBUG
/// Read-only production state for timing verification; absent from release builds.
struct QueuePillObservation: Equatable {
    let countingVisible: Bool
    let count: Int
    var mode: QueuePillVisualMode = .icon
    var completionFill = false
}
struct QueuePillObservationKey: PreferenceKey {
    static let defaultValue: QueuePillObservation? = nil
    static func reduce(value: inout QueuePillObservation?, nextValue: () -> QueuePillObservation?) {
        if let next = nextValue() { value = next }
    }
}

struct QueuePillGraceHarness: View {
    @State private var count = 0
    @State private var started: Double?
    @State private var firstVisible = "pending"
    @State private var finished = false

    private var snapshot: TransferQueueSnapshot {
        let items = (0..<count).map { index in
            TransferQueueItem(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                file: CameraFile(id: UInt32(index + 1), storageID: 1, format: 0x3801,
                                 size: 2048, fileName: "WAIT_\(index).JPG",
                                 captureDate: nil, isProtected: false))
        }
        return .init(items: items, isTransferring: true, pauseAfterCurrent: false)
    }

    var body: some View {
        VStack(spacing: 32) {
            QueuePill(snapshot: snapshot, activeProgress: nil, heldCount: 0)
            Button("Start updates") {
                started = ProcessInfo.processInfo.systemUptime
                count = 1
            }
            .accessibilityIdentifier("grace-start")
            .disabled(started != nil)
            Text(firstVisible).accessibilityIdentifier("grace-first-visible")
            Text(finished ? "finished" : "waiting").accessibilityIdentifier("grace-updates")
        }
        .onPreferenceChange(QueuePillObservationKey.self) { observation in
            guard let observation, observation.countingVisible,
                  let started, firstVisible == "pending" else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            firstVisible = "\(Int(elapsed * 1000)),\(observation.count)"
        }
        .task(id: started) {
            guard started != nil else { return }
            for next in 2...11 {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                count = next
            }
            finished = true
        }
    }
}

/// Real QueuePill and button style, with deterministic snapshots and no camera.
struct QueueTopPillPresentationHarness: View {
    @State private var phase = 0
    @State private var activations = 0
    @State private var observedProgress = "pending"
    @State private var observedFrame = "pending"
    private var snapshot: TransferQueueSnapshot {
        let count = phase == 0 ? 9 : phase == 1 ? 3 : phase == 2 ? 2 : 1
        let items = (1...count).map { index in
            var item = TransferQueueItem(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + (phase == 0 ? 0 : phase == 1 ? 1000 : 2000)))!,
                file: CameraFile(id: UInt32(index), storageID: 1, format: 0x3801, size: 2048,
                                 fileName: "PILL_\(index).JPG", captureDate: nil, isProtected: false))
            item.status = phase == 3
                ? (ProcessInfo.processInfo.arguments.contains("--queue-top-pill-success") ? .completed : .cancelled)
                : phase == 2 ? .transferring : phase == 1 && index == 1 ? .transferring : .waiting
            item.progress = phase == 1 && index == 1 ? 0.25 : 0
            item.isGeneratingFrame = phase == 2
            item.bytesPerSecond = phase == 1 && index == 1 ? 10 * 1024 * 1024 : 0
            return item
        }
        return .init(items: items, isTransferring: phase != 0, pauseAfterCurrent: false)
    }

    private func recordFrame(_ frame: CGRect) {
        observedFrame = [frame.minX, frame.minY, frame.width, frame.height]
            .map { String(format: "%.3f", Double($0)) }.joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 40) {
            HStack {
                Spacer()
                QueuePill(snapshot: snapshot, activeProgress: nil, heldCount: 0,
                          onClick: { activations += 1 })
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { recordFrame(proxy.frame(in: .global)) }
                                    .onChange(of: proxy.frame(in: .global)) { recordFrame($0) }
                            }
                        }
                .accessibilityIdentifier("queue-top-pill")
            }
            .frame(width: 300)
            Button("Next state") { phase = (phase + 1) % 4 }
                .accessibilityIdentifier("queue-top-pill-next")
            Text("\(activations)").accessibilityIdentifier("queue-top-pill-activations")
            Text(observedFrame).font(.caption2)
                .accessibilityIdentifier("queue-top-pill-frame")
            Text(observedProgress).font(.caption2)
                .accessibilityIdentifier("queue-top-pill-progress")
        }
        .onPreferenceChange(SmoothTransferProgressObservationKey.self) { observation in
            guard let observation else { return }
            observedProgress = "\(observation.key ?? "nil")|\(String(format: "%.3f", observation.value))"
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZTransferColors.background)
    }
}
#endif

/// Geometry changes every scroll frame, but is consumed only by hit/flight/
/// dismissal calculations. Keep current snapshots without invalidating the
/// whole grid, regrouping every day and rebuilding the preview each frame.
final class PhotoListGeometryCache {
    // Read at interaction/visibility decisions. Workspace layer translation
    // changes global coordinates every frame, not the grid layout or catalog.
    var viewportBounds: CGRect = .zero
    var topControlsBounds: CGRect = .zero
    var scrollItemIndices: [String: Int] = [:]
    var scrollItemFrames: [String: CGRect] = [:]
    var photoListScrollOffset: CGFloat = 0
    var cellBounds: [PhotoListCellID: CGRect] = [:]
    var sectionEnqueueBounds: [String: CGRect] = [:]
}

/// Android QueueFlightGhost/PreviewCropFlightGhost: immutable image layers,
/// with only compositor properties updated by the frame clock. No SwiftUI
/// Image construction, layout or image decoding on animation frames.
struct QueueFlightLayerSpec {
    let image: UIImage?
    let size: CGSize
    var corner: CGFloat = 0
    var borderAlpha: CGFloat = 0
    var background: UIColor = .clear
    var aspectFill = true
    var showsPlaceholder = false
}

struct QueueFlightLayerFrame {
    var center: CGPoint
    var scale: CGFloat = 1
    var rotation: CGFloat = 0 // degrees
    var alpha: CGFloat = 1
}

struct QueueFlightLayers: UIViewRepresentable {
    let startedAt: Date
    let duration: TimeInterval
    let specs: [QueueFlightLayerSpec]
    let frames: (TimeInterval) -> [QueueFlightLayerFrame]

    func makeUIView(context: Context) -> QueueFlightLayerSurface { QueueFlightLayerSurface() }
    func updateUIView(_ view: QueueFlightLayerSurface, context: Context) {
        view.configure(startedAt: startedAt, duration: duration, specs: specs, frames: frames)
    }
    static func dismantleUIView(_ view: QueueFlightLayerSurface, coordinator: ()) { view.stop() }
}

final class QueueFlightLayerSurface: UIView {
    private(set) var imageLayers: [CALayer] = []
    private(set) var displayLink: CADisplayLink?
    private var epoch = Date.distantPast
    private var duration: TimeInterval = 0
    private var frameProvider: ((TimeInterval) -> [QueueFlightLayerFrame])?
    private var monotonicStart: CFTimeInterval = 0
    private static let placeholderImage = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
        UIImage(systemName: "photo")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            .draw(in: CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    @MainActor
    private final class Target: NSObject {
        weak var owner: QueueFlightLayerSurface?
        init(_ owner: QueueFlightLayerSurface) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { startClockIfNeeded() }
    }

    func configure(startedAt: Date, duration: TimeInterval, specs: [QueueFlightLayerSpec],
                   frames: @escaping (TimeInterval) -> [QueueFlightLayerFrame]) {
        let newFlight = epoch != startedAt
        if newFlight { epoch = startedAt; monotonicStart = CACurrentMediaTime() - Date().timeIntervalSince(startedAt) }
        self.duration = duration; frameProvider = frames
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while imageLayers.count > specs.count { imageLayers.removeLast().removeFromSuperlayer() }
        while imageLayers.count < specs.count {
            let image = CALayer(); image.opacity = 0
            layer.addSublayer(image); imageLayers.append(image)
        }
        for (image, spec) in zip(imageLayers, specs) {
            image.bounds = CGRect(origin: .zero, size: spec.size)
            image.contents = spec.image?.cgImage
            image.contentsGravity = spec.aspectFill ? .resizeAspectFill : .resize
            image.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            image.cornerRadius = spec.corner; image.masksToBounds = spec.corner > 0
            image.borderColor = UIColor.white.withAlphaComponent(spec.borderAlpha).cgColor
            image.borderWidth = spec.borderAlpha > 0 ? 1 : 0
            image.backgroundColor = spec.background.cgColor
            if spec.showsPlaceholder && spec.image == nil {
                let icon = image.sublayers?.first ?? CALayer()
                if icon.superlayer == nil { image.addSublayer(icon) }
                icon.contents = Self.placeholderImage.cgImage
                icon.contentsScale = image.contentsScale
                icon.frame = CGRect(x: (spec.size.width - 20) / 2, y: (spec.size.height - 20) / 2, width: 20, height: 20)
            } else { image.sublayers?.forEach { $0.removeFromSuperlayer() } }
        }
        CATransaction.commit()
        render(elapsed: CACurrentMediaTime() - monotonicStart)
        startClockIfNeeded()
    }
    private func startClockIfNeeded() {
        if frameProvider != nil, displayLink == nil, CACurrentMediaTime() - monotonicStart < duration {
            let link = CADisplayLink(target: Target(self), selector: #selector(Target.tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }
    private func tick(_ link: CADisplayLink) {
        let elapsed = link.timestamp - monotonicStart
        render(elapsed: elapsed)
        if elapsed >= duration { stop() }
    }
    func render(elapsed: TimeInterval) {
        guard let frameProvider else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (image, frame) in zip(imageLayers, frameProvider(elapsed)) {
            image.position = frame.center
            image.opacity = Float(min(max(frame.alpha, 0), 1))
            image.setAffineTransform(CGAffineTransform(rotationAngle: frame.rotation * .pi / 180)
                .scaledBy(x: frame.scale, y: frame.scale))
        }
        CATransaction.commit()
    }
    func stop() { displayLink?.invalidate(); displayLink = nil }
}

func queueFlightPoint(progress: CGFloat, start: CGPoint, end: CGPoint) -> CGPoint {
    let t = min(max(progress, 0), 1)
    let dx = abs(end.x - start.x)
    let lift = min(90, 36 + 0.35 * dx)
    let control = CGPoint(x: (start.x + end.x) / 2 - 52 * (1 - min(dx / 160, 1)),
        y: max(min(start.y, end.y) - lift, (48 - start.y - end.y) / 2))
    return quadraticBezier(start: start, control: control, end: end, t: t)
}

/// Android empty-list/filter pulse: 1600ms each direction, FastOutSlowIn.
/// One animation transaction; no SwiftUI timeline recomputes the icon per frame.
private struct PhotoListEmptyPulse: ViewModifier {
    @State private var bright = false
    func body(content: Content) -> some View {
        content.opacity(bright ? 0.6 : 0.35)
            .onAppear {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.6).repeatForever(autoreverses: true)) { bright = true }
            }
            .onDisappear { bright = false }
    }
}
