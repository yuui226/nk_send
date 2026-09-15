import SwiftUI
import UIKit

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

private struct PhotoListWorkspaceTransition: AnimatableModifier {
    var progress: CGFloat
    let horizontalMultiplier: CGFloat
    let initialOpacity: CGFloat
    let initialScale: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(initialOpacity + (1 - initialOpacity) * progress)
            .offset(x: UIScreen.main.bounds.width * horizontalMultiplier * (1 - progress))
            .scaleEffect(initialScale + (1 - initialScale) * progress, anchor: .center)
    }
}

private let photoQueueWorkspaceAnimation =
    Animation.timingCurve(0.22, 0.84, 0.24, 1.0, duration: 0.34)

@MainActor struct PhotoListView: View {
    @StateObject private var model: PhotoListViewModel
    @StateObject private var queueModel: TransferQueueViewModel
    @ObservedObject private var directoryStore: DirectoryAccessStore
    let effectsStore: PhotoEffectsStore
    let onDisconnect: () -> Void
    private let session: CameraSession?
    @AppStorage("tap_to_preview") private var tapToPreview = false
    @State private var selectedFile: CameraFile?
    @State private var showingFilter = false
    @State private var filterAnchor: CGRect = .zero
    @State private var showingQueue = false
    @AppStorage("defer_transfer_start") private var deferTransferStart = false
    @AppStorage("organize_transfers_by_date") private var organizeByDate = false
    @AppStorage("collapse_burst_photos") private var collapseBurstPhotos = true
    @AppStorage("thumbnail_columns") private var thumbnailColumns = 3
    @State private var expandedBurstIDs: Set<String> = []
    @State private var collapsedDays: Set<String> = []
    @State private var showTopButton = false
    @State private var showingRemote = false
    @State private var showingSettings = false
    @State private var settingsAnchor: CGRect = .zero
    @State private var signalExpanded = false
    @State private var effectPreviewSource: UIImage?
    @State private var effectPreviewExif: PhotoExif?
    @State private var effectPreviewGeneration = 0
    @State private var effectPreviewRequested = false
    @State private var effectPreviewFileKey: String?
    @State private var topControlsVisible = true
    @State private var cellBounds: [UInt32: CGRect] = [:]
    @State private var queueTargetBounds: CGRect = .zero
    @State private var queueFlights: [PhotoListQueueFlight] = []
    @State private var heldFlightCount = 0
    @State private var queueImpact = 0

    init(repository: CameraRepository, queue: TransferQueue = TransferQueue(), directory: DirectoryAccessStore = DirectoryAccessStore(), effectsStore: PhotoEffectsStore = PhotoEffectsStore(), onDisconnect: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PhotoListViewModel(repository: repository))
        _queueModel = StateObject(wrappedValue: TransferQueueViewModel(queue: queue))
        _directoryStore = ObservedObject(wrappedValue: directory)
        self.effectsStore = effectsStore
        self.onDisconnect = onDisconnect; self.session = nil
    }

    init(session: CameraSession, queue: TransferQueue, directory: DirectoryAccessStore = DirectoryAccessStore(), effectsStore: PhotoEffectsStore = PhotoEffectsStore(), onDisconnect: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PhotoListViewModel(session: session))
        _queueModel = StateObject(wrappedValue: TransferQueueViewModel(queue: queue))
        _directoryStore = ObservedObject(wrappedValue: directory)
        self.effectsStore = effectsStore
        self.onDisconnect = onDisconnect; self.session = session
    }

    private var columns: [GridItem] {
        // Android clamps the persisted preference to one through four columns;
        // the grid uses the same 6dp inter-cell spacing on both axes.
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: min(max(thumbnailColumns, 1), 4))
    }

    var body: some View {
        ZStack {
            ZTransferColors.background.ignoresSafeArea()
            if showingQueue {
                TransferQueueView(model: queueModel, session: session, directory: directoryStore) {
                    withAnimation(photoQueueWorkspaceAnimation) {
                        showingQueue = false
                    }
                }
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalMultiplier: 1, initialOpacity: 0.82, initialScale: 0.985),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalMultiplier: 1, initialOpacity: 0.82, initialScale: 0.985)
                    ),
                    removal: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalMultiplier: 1, initialOpacity: 0.82, initialScale: 0.985),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalMultiplier: 1, initialOpacity: 0.82, initialScale: 0.985)
                    )
                ))
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
                    LazyVStack(alignment: .leading, spacing: 18) {
                    switch model.loadState {
                    case .idle, .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 48)
                    case let .failed(message):
                        Text(message).zTransferText(size: ZTransferMetrics.body).padding()
                    case .loaded:
                        if model.sections.isEmpty {
                            PhotoListEmptyState(filterActive: model.filter.isActive,
                                                usb: session?.isUSB == true,
                                                onClearFilter: model.clearFilter)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 150)
                        } else {
                            ForEach(model.sections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                Button {
                                    withAnimation(ZTransferMotion.standard) {
                                        if collapsedDays.contains(section.day) { collapsedDays.remove(section.day) }
                                        else { collapsedDays.insert(section.day) }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(section.day == PhotoCatalogGrouping.unknownDay
                                             ? AppLocalized.resource("unknown_date")
                                             : formatDateHeader(section.day))
                                            .zTransferText(size: ZTransferMetrics.body, weight: .bold)
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(ZTransferColors.accentBlue)
                                            .rotationEffect(.degrees(collapsedDays.contains(section.day) ? 0 : 180))
                                        Text("\(section.files.count)")
                                            .zTransferText(size: ZTransferMetrics.caption)
                                            .monospacedDigit()
                                    }
                                    // Android's date control is an intrinsic
                                    // width capsule; a trailing Spacer here made
                                    // it stretch across the entire grid.
                                    .padding(.horizontal, 14)
                                    .frame(height: 28)
                                    .background {
                                        Capsule()
                                            .fill(Color.white.opacity(0.78))
                                            .overlay {
                                                Capsule().stroke(Color.white.opacity(0.95), lineWidth: 1)
                                            }
                                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer(minLength: 0)
                                Button { enqueueSection(section.files) } label: {
                                    Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(ZTransferColors.accentBlue)
                                        .frame(width: 40, height: 28)
                                        .background(Color.white.opacity(0.78), in: Capsule())
                                        .overlay(Capsule().stroke(Color.white.opacity(0.95), lineWidth: 1))
                                }.buttonStyle(.plain)
                                }
                                if !collapsedDays.contains(section.day) { LazyVGrid(columns: columns, spacing: 6) {
                                        ForEach(photoGridEntries(section.files, burstIDByFile: model.burstIDByFile,
                                                                 collapse: collapseBurstPhotos, expandedIDs: expandedBurstIDs)) { entry in
                                        let file = entry.firstFile
                                        VStack(alignment: .leading, spacing: 0) {
                                            if let session {
                                                if case let .burst(group) = entry {
                                                    BurstThumbnailView(session: session, group: group,
                                                                       transferred: group.files.allSatisfy { model.transferredFileIDs.contains($0.id) },
                                                                       expanded: expandedBurstIDs.contains(group.id),
                                                                       onExpand: { toggleBurst(group.id) },
                                                                       onEnqueue: { enqueueSection(group.files) })
                                                } else {
                                                    CameraThumbnailView(session: session, handle: file.id, file: file,
                                                                        transferred: model.transferredFileIDs.contains(file.id),
                                                                        inBurst: model.burstIDByFile[file.id] != nil,
                                                                        queueTask: queueModel.task(for: file.id), liveProgress: queueModel.activeProgress)
                                                }
                                                } else { PlaceholderThumbnail() }
                                        }
                                        // The grid proposes a width but may let a
                                        // child determine the row height. Lock the
                                        // cell itself to a square before gestures
                                        // and overlays are applied.
                                        .aspectRatio(1, contentMode: .fill)
                                        .frame(maxWidth: .infinity, minHeight: 0)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .contentShape(Rectangle())
                                        .background {
                                            GeometryReader { proxy in
                                                Color.clear.preference(
                                                    key: PhotoListCellBoundsPreferenceKey.self,
                                                    value: [file.id: proxy.frame(in: .global)]
                                                )
                                            }
                                        }
                                        .onTapGesture { handleTap(entry, file: file) }
                                        .onLongPressGesture {
                                            if case let .burst(group) = entry {
                                                withAnimation(ZTransferMotion.standard) { expandedBurstIDs.insert(group.id) }
                                                selectedFile = group.files[0]
                                            } else if !tapToPreview { selectedFile = file }
                                        }

                                    }
                                } }
                                }
                            }
                        }
                    }
                    // Match Android's 12dp list inset so thumbnails align with
                    // the floating top controls instead of leaving a wider gutter.
                    }.padding(.horizontal, 12).padding(.top, 8)
                }
                .coordinateSpace(name: "photo-list-scroll")
                .onPreferenceChange(PhotoListCellBoundsPreferenceKey.self) { bounds in
                    cellBounds.merge(bounds) { _, latest in latest }
                }
                .onPreferenceChange(PhotoListScrollOffsetKey.self) { value in
                    showTopButton = value < -360
                }
                .refreshable { await model.reload() }
                .overlay(alignment: .bottomTrailing) {
                    if showTopButton {
                        Button {
                            withAnimation(ZTransferMotion.standard) { reader.scrollTo("photo-list-top", anchor: .top) }
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                                .frame(width: 44, height: 44)
                                .background(.thinMaterial, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 18).padding(.bottom, 22)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .overlay(alignment: .bottomLeading) { remoteEntryOverlay }
                // Keep the controls in the safe-area header. This gives them
                // a stable top position instead of relying on the scroll view
                // body's proposed height.
                .safeAreaInset(edge: .top, spacing: 0) {
                    photoListTopControls
                }
                // The two workspace pages are a horizontal pair. The files
                // page enters from the left when returning from the queue and
                // keeps a subtle scale/opacity settle during the hand-off.
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalMultiplier: -1, initialOpacity: 0.72, initialScale: 0.985),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalMultiplier: -1, initialOpacity: 0.72, initialScale: 0.985)
                    ),
                    removal: .modifier(
                        active: PhotoListWorkspaceTransition(progress: 0, horizontalMultiplier: -1, initialOpacity: 0.72, initialScale: 0.985),
                        identity: PhotoListWorkspaceTransition(progress: 1, horizontalMultiplier: -1, initialOpacity: 0.72, initialScale: 0.985)
                    )
                ))
            }
            }
            if selectedFile != nil { previewOverlay }
            // A single workspace-owned control survives both page transitions.
            queueTopRightControls
                .padding(.horizontal, 12)
                .padding(.top, 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            queueFlightOverlay
        }
        .task {
            if let session {
                await session.setPreferHighThroughputTransfers(!showingRemote)
                queueModel.attach(session: session, directory: directoryStore.directoryURL)
            }
            model.setNewMediaHandler { files in
                guard UserDefaults.standard.bool(forKey: "auto_transfer_new_media"), let session,
                      let directory = directoryStore.directoryURL else { return }
                let deferStart = UserDefaults.standard.bool(forKey: "defer_transfer_start")
                queueModel.enqueueAutomatic(files, session: session, directory: directory,
                                            autoStart: !deferStart, organizeByDate: organizeByDate,
                                            effects: effectsStore.settings)
            }
            model.load()
        }
        .onChange(of: showingRemote) { remote in
            // MainActivity.shouldPreferHighThroughputTransfers: both files and
            // transfer routes enable this; monitoring disables it.
            if let session { Task { await session.setPreferHighThroughputTransfers(!remote) } }
        }
        .onDisappear {
            if let session { Task { await session.setPreferHighThroughputTransfers(false) } }
        }
        .onChange(of: collapseBurstPhotos) { enabled in
            if !enabled { expandedBurstIDs.removeAll() }
        }
        .onChange(of: model.sections) { sections in
            let valid = Set(sections.map(\.day))
            collapsedDays = collapsedDays.intersection(valid)
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
        .onChange(of: queueModel.snapshot.isTransferring) { busy in
            model.setTransferBusy(busy)
            if let session { Task { await session.setTransfersBusy(busy) } }
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
        .fullScreenCover(isPresented: $showingRemote) {
            if let session {
                RemoteView(session: session) {
                    model.resumeAfterRemote()
                    model.wakeThumbnailFill()
                }
            }
        }
                .overlay {
            if showingSettings {
                SettingsPopupOverlay(
                    isPresented: $showingSettings,
                    showPhotoEffectsEntry: true,
                    effectsStore: effectsStore,
                    directory: directoryStore,
                    anchor: settingsAnchor,
                    effectPreviewSource: effectPreviewSource,
                    effectPreviewExif: effectPreviewExif,
                    onEffectPreviewRequested: requestEffectPreview
                )
                .ignoresSafeArea()
            }
            if showingFilter {
                let files = model.availableFiles
                PhotoFilterPopupOverlay(
                    isPresented: $showingFilter,
                    anchor: filterAnchor,
                    initial: model.filter,
                    availableExtensions: Array(Set(files.map(\.fileExtension))).sorted().isEmpty
                        ? [".jpg", ".nef", ".mp4"]
                        : Array(Set(files.map(\.fileExtension))).sorted(),
                    availableStorageSlots: Array(Set(files.flatMap { $0.storageIDs })).sorted(),
                    suggestedDate: model.latestEffectPreviewFile?.captureDate,
                    onChange: model.setFilter,
                )
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var previewOverlay: some View {
        if let session {
                let files = model.sections.flatMap(\.files)
                PhotoPreviewView(session: session, queueModel: queueModel, files: files,
                                 burstIDByFile: model.burstIDByFile,
                                 transferredFileIDs: model.transferredFileIDs, selectedFile: $selectedFile,
                                 directory: directoryStore.directoryURL,
                                 organizeByDate: organizeByDate,
                                 queueTarget: queueTargetBounds == .zero ? nil : queueTargetBounds,
                                 initialExpandedBurstIDs: expandedBurstIDs,
                                 collapseBursts: collapseBurstPhotos,
                                 onBurstChanged: { id, expanded in
                                     if expanded { expandedBurstIDs.insert(id) }
                                     else { expandedBurstIDs.remove(id) }
                                 }) { file in
                    guard directoryStore.directoryURL != nil else {
                        selectedFile = nil
                        showingSettings = true
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
                        showingSettings = true
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
                    heldFlightCount += count
                } onQueueFlightFinished: { count in
                    heldFlightCount = max(0, heldFlightCount - count)
                }
                .onAppear { model.pauseForPreview() }
                .onDisappear {
                    model.resumeAfterPreview()
                    model.wakeThumbnailFill()
                }
        }
    }

    private var photoListTopControls: some View {
        HStack(spacing: 8) {
            if topControlsVisible {
                HStack(spacing: 8) {
                    Button { showingSettings = true } label: {
                        DoubleZMark(tint: ZTransferColors.primaryText)
                            .frame(width: 20 * DoubleZMark.aspectRatio, height: 20)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                    }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PhotoListSettingsAnchorPreferenceKey.self,
                                                   value: proxy.frame(in: .global))
                        }
                    }

                    Button {
                        if session?.wirelessMode != .sta { signalExpanded.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            PhotoListSignalIcon(isUSB: session?.isUSB == true,
                                                wirelessMode: session?.wirelessMode)
                            if signalExpanded && session?.wirelessMode != .sta {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(minWidth: 40, minHeight: 36, maxHeight: 36)
                    }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))

                    Button { showingFilter = true } label: {
                        PhotoListFilterIcon(active: model.filter.isActive)
                            .frame(width: 20, height: 20)
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PhotoListFilterAnchorPreferenceKey.self,
                                                   value: proxy.frame(in: .global))
                        }
                    }
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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .animation(ZTransferMotion.standard, value: queueModel.snapshot.items.count)
        .onPreferenceChange(PhotoListSettingsAnchorPreferenceKey.self) { settingsAnchor = $0 }
        .onPreferenceChange(PhotoListFilterAnchorPreferenceKey.self) { filterAnchor = $0 }
    }

    /// Android keeps queue execution and the queue pill outside the files ↔
    /// transfer page transition. Reusing this group in both pages preserves
    /// one source of truth for start/pause availability and pill animation.
    private var queueTopRightControls: some View {
        HStack(spacing: 8) {
            let transferCount = queueModel.snapshot.items.filter { $0.status == .waiting || $0.status == .transferring }.count
            if queueModel.snapshot.isTransferring && transferCount > 1 {
                Button { queueModel.pause() } label: {
                    Image(systemName: "pause.fill").frame(width: 36, height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                .accessibilityLabel(AppLocalized.resource(queueModel.snapshot.pauseAfterCurrent
                                                          ? "cd_pause_after_current_scheduled"
                                                          : "cd_pause_after_current"))
            } else if !queueModel.snapshot.isTransferring && queueModel.snapshot.items.contains(where: { $0.status == .waiting }) {
                Button {
                    guard let session, let directory = directoryStore.directoryURL else { return }
                    queueModel.start(session: session, directory: directory)
                } label: {
                    Image(systemName: "play.fill").frame(width: 36, height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                .disabled(session == nil || directoryStore.directoryURL == nil)
                .opacity(session == nil || directoryStore.directoryURL == nil ? 0.45 : 1)
                .accessibilityLabel(AppLocalized.resource("cd_start_transfers"))
            }

            Button {
                    guard !showingQueue else { return }
                    withAnimation(photoQueueWorkspaceAnimation) {
                        showingQueue = true
                    }
                } label: {
                    if !queueModel.snapshot.items.isEmpty {
                        QueuePill(snapshot: queueModel.snapshot, activeProgress: queueModel.activeProgress,
                              heldCount: heldFlightCount, impact: queueImpact)
                        .frame(height: 36)
                        .fixedSize(horizontal: true, vertical: false)
                    } else {
                    PhotoListQueueIcon()
                        .frame(width: 20, height: 20)
                        .frame(width: 40, height: 36)
                    }
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PhotoListQueueTargetPreferenceKey.self,
                                               value: proxy.frame(in: .global))
                    }
                }
                .scaleEffect(heldFlightCount > 0 ? 1.06 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.68), value: heldFlightCount > 0)
                .accessibilityLabel(AppLocalized.resource("cd_transfer"))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(ZTransferMotion.standard, value: queueModel.snapshot.items)
        .animation(ZTransferMotion.standard, value: queueModel.snapshot.isTransferring)
        .onPreferenceChange(PhotoListQueueTargetPreferenceKey.self) { queueTargetBounds = $0 }
    }

    /// Android requests the latest visible file on entering Settings: publish
    /// its cached thumbnail first, then upgrade the same identity to the FHD
    /// preview and EXIF. A late response for an older file is discarded.
    private func requestEffectPreview() {
        effectPreviewRequested = true
        guard let session, let file = model.latestEffectPreviewFile else { return }
        let key = "\(file.id)|\(file.fileName)|\(file.size)|\(file.captureDate ?? "")"
        guard effectPreviewFileKey != key || (effectPreviewSource == nil && effectPreviewExif == nil) else { return }
        effectPreviewFileKey = key
        effectPreviewGeneration &+= 1
        let generation = effectPreviewGeneration
        Task {
            await session.setEffectPreviewActive(true)
            defer {
                Task { @MainActor in
                    guard generation == effectPreviewGeneration else { return }
                    await session.setEffectPreviewActive(false)
                    // Android's fill collector is resumed by the same state
                    // transition that releases the effect-preview channel.
                    // Without an explicit wake, a worker that yielded while
                    // the preview was active would remain stopped until an
                    // unrelated filter or transfer change occurred.
                    model.wakeThumbnailFill()
                }
            }
            if let data = try? await session.cachedThumbnail(file: file), let image = UIImage(data: data) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == effectPreviewGeneration else { return }
                    effectPreviewSource = image
                }
            }
            // Android reads EXIF only after a valid FHD preview succeeds.
            let previewData = try? await session.preview(handle: file.id)
            guard let previewData, UIImage(data: previewData) != nil else { return }
            let exif = try? await session.exif(file: file)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == effectPreviewGeneration else { return }
                effectPreviewExif = exif
                effectPreviewSource = UIImage(data: previewData)
            }
        }
    }

    @ViewBuilder
    private var remoteEntryOverlay: some View {
        if session != nil {
            Button { showingRemote = true } label: {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.leading, 18).padding(.bottom, 22)
        }
    }

    private func toggleBurst(_ id: String) {
        withAnimation(ZTransferMotion.standard) {
            if expandedBurstIDs.contains(id) { expandedBurstIDs.remove(id) }
            else { expandedBurstIDs.insert(id) }
        }
    }

    private func enqueueSection(_ files: [CameraFile]) {
        guard directoryStore.directoryURL != nil || deferTransferStart else { showingSettings = true; return }
        for file in files {
            if deferTransferStart { queueModel.enqueue(file, organizeByDate: organizeByDate, effects: effectsStore.settings) }
            else { queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL, organizeByDate: organizeByDate, effects: effectsStore.settings) }
        }
    }

    private func handleTap(_ entry: PhotoGridEntry, file: CameraFile) {
        if case let .burst(group) = entry {
            toggleBurst(group.id)
            return
        }
        if tapToPreview {
            selectedFile = file
        } else if directoryStore.directoryURL == nil {
            // Android routes a transfer attempt with no valid destination to the
            // existing settings overlay; it does not enqueue an unusable task.
            showingSettings = true
        } else if !deferTransferStart {
            queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL, organizeByDate: organizeByDate, effects: effectsStore.settings)
            startListQueueFlight(for: file)
        } else {
            queueModel.enqueue(file, organizeByDate: organizeByDate, effects: effectsStore.settings)
            startListQueueFlight(for: file)
        }
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

    private func startListQueueFlight(for file: CameraFile) {
        guard let from = cellBounds[file.id], !from.isEmpty,
              !queueTargetBounds.isEmpty, !queueTargetBounds.isInfinite,
              !queueTargetBounds.isNull else { return }
        let id = UUID()
        queueFlights.append(PhotoListQueueFlight(id: id, file: file, from: from, target: queueTargetBounds))
        heldFlightCount += 1
        // Start the flight immediately. Thumbnail lookup is decoration and must
        // never delay (or suppress) the visible Android-style flight.
        withAnimation(.timingCurve(0.5, 0.0, 0.8, 0.35, duration: 0.56)) {
            if let index = queueFlights.firstIndex(where: { $0.id == id }) {
                queueFlights[index].progress = 1
            }
        }
        Task { @MainActor in
            // Android's flight uses the synchronous in-memory thumbnail cache;
            // it never adds a camera request just to decorate a 560ms flight.
            if let session {
               let cached = try? await session.cachedThumbnail(file: file)
               let data: Data?
               if let cached { data = cached }
               else { data = try? await session.thumbnail(file: file) }
               if let data, let image = UIImage(data: data),
               let index = queueFlights.firstIndex(where: { $0.id == id }) {
                queueFlights[index].image = image
               }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            heldFlightCount = max(0, heldFlightCount - 1)
            queueImpact &+= 1
            queueFlights.removeAll { $0.id == id }
        }
    }
}

private struct PhotoListQueueFlight: Identifiable {
    let id: UUID
    let file: CameraFile
    let from: CGRect
    let target: CGRect
    var progress: CGFloat = 0
    var image: UIImage?
}

private struct PhotoListQueueFlightView: View {
    let flight: PhotoListQueueFlight
    let viewport: CGRect
    let target: CGRect

    var body: some View {
        Group {
            if let image = flight.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZTransferColors.accentBlue.overlay {
                    Image(systemName: "photo").foregroundStyle(.white)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.8), lineWidth: 1))
        .modifier(QueueFlightArc(
            progress: flight.progress,
            start: CGPoint(x: flight.from.midX - viewport.minX, y: flight.from.midY - viewport.minY),
            end: CGPoint(x: target.maxX - 28 - viewport.minX, y: target.midY - viewport.minY)
        ))
        .animation(.timingCurve(0.5, 0.0, 0.8, 0.35, duration: 0.56), value: flight.progress)
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

private struct PhotoListCellBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [UInt32: CGRect] = [:]
    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct PhotoListQueueTargetPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The Android SignalPill has a dedicated USB mark and a four-bar STA mark.
/// AP has no public RSSI API on iOS, so it retains the existing Wi-Fi glyph
/// until a platform-equivalent signal value is available; no synthetic level
/// is introduced.
struct PhotoListSignalIcon: View {
    let isUSB: Bool
    let wirelessMode: WirelessMode?

    var body: some View {
        if isUSB {
            ClassicUSBIcon(tint: ZTransferColors.accentBlue)
                .frame(width: 18, height: 18)
        } else if wirelessMode == .sta {
            Canvas { context, size in
                let width = size.width * 0.16
                let gap = size.width * 0.10
                let heights: [CGFloat] = [0.30, 0.48, 0.66, 0.84].map { size.height * $0 }
                let total = width * 4 + gap * 3
                let start = (size.width - total) / 2
                for (index, height) in heights.enumerated() {
                    let x = start + CGFloat(index) * (width + gap)
                    let rect = CGRect(x: x, y: size.height - height, width: width, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: width * 0.35), with: .color(ZTransferColors.accentBlue))
                }
            }
            .frame(width: 19, height: 18)
            .accessibilityLabel(AppLocalized.resource("sta_signal_connected"))
        } else {
            Image(systemName: ZTransferIcon.wifi)
                .font(.system(size: 17, weight: .semibold))
        }
    }
}

/// Android's hand-drawn funnel mark, kept as a line icon instead of the
/// circular SF Symbols variant so the compact top buttons share one visual
/// language across platforms.
private struct PhotoListFilterIcon: View {
    let active: Bool

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
            let color = active ? ZTransferColors.accentBlue : ZTransferColors.primaryText
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

private struct PhotoListSettingsAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct PhotoListFilterAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private func formatDateHeader(_ raw: String) -> String {
    guard raw.count == 8,
          raw.allSatisfy(\.isNumber) else { return raw }
    let chars = Array(raw)
    return "\(chars[0])\(chars[1])\(chars[2])\(chars[3])-\(chars[4])\(chars[5])-\(chars[6])\(chars[7])"
}

private struct PlaceholderThumbnail: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.08))
            .aspectRatio(1, contentMode: .fit)
    }
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
                Button(AppLocalized.resource("clear_filters"), action: onClearFilter)
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 18))
            }
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

struct QueuePill: View {
    let snapshot: TransferQueueSnapshot
    let activeProgress: TransferActiveProgress?
    let heldCount: Int
    var impact: Int = 0
    @State private var showDoneLabel = false
    @State private var sawActiveBatch = false
    @State private var previousAllDone: Bool?
    @State private var countingVisible = false
    @State private var doneTask: Task<Void, Never>?
    @State private var impactScale = false
    private var downloadRemaining: Int {
        snapshot.items.reduce(into: 0) { count, item in
            if item.status == .waiting || item.status == .transferring {
                count += 1
            }
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

    private var activeSpeed: Int64 {
        guard snapshot.isTransferring else { return 0 }
        return activeProgress?.retainedBytesPerSecond ?? activeItem?.bytesPerSecond ?? 0
    }

    private var displayRemainingCount: Int { max(0, downloadRemaining - heldCount) }
    private var hasActive: Bool { downloadRemaining > 0 || generationCount > 0 || heldCount > 0 }
    private var allDone: Bool { downloadRemaining == 0 && generationCount == 0 }
    private var paused: Bool { !snapshot.isTransferring && downloadRemaining > 0 }
    private var hasCancelled: Bool { snapshot.items.contains { $0.status == .cancelled } }
    private var collapsedToIcon: Bool {
        // Keep the carrier visible while a thumbnail is flying. Collapsing it
        // to the checklist icon changes the target frame mid-flight and makes
        // the Android-style animation appear to disappear.
        return (!hasActive && !countingVisible) || (allDone && !showDoneLabel && heldCount == 0)
    }

    var body: some View {
        HStack(spacing: 5) {
            if showDoneLabel {
                // Android keeps this transient badge literal across locales.
                Text("Done")
                    .zTransferTypography(.labelLarge, weight: .bold)
                    .foregroundStyle(ZTransferColors.statusConnected)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            } else if collapsedToIcon {
                PhotoListQueueIcon()
                    .frame(width: 20, height: 20)
                    .scaleEffect(hasActive ? 1 : 0.9)
            } else if paused {
                Text("\(displayRemainingCount)")
                    .zTransferTypography(.labelLarge, weight: .bold)
                    .foregroundStyle(ZTransferColors.primaryText)
                    .monospacedDigit()
                    .id("paused-\(displayRemainingCount)")
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
            } else if downloadRemaining == 0, generationCount > 0 {
                HStack(spacing: 6) {
                    Text(AppLocalized.resource("queue_pill_generating"))
                        .zTransferTypography(.labelLarge, weight: .bold)
                        .foregroundStyle(ZTransferColors.accentBlue)
                    Text("\(generationCount)")
                        .zTransferTypography(.labelLarge, weight: .bold)
                        .foregroundStyle(ZTransferColors.primaryText)
                        .monospacedDigit()
                }
            } else {
                HStack(spacing: 8) {
                    if activeSpeed > 0 {
                        Text(speedText(activeSpeed))
                            .zTransferTypography(.labelMedium, weight: .bold)
                            .foregroundStyle(ZTransferColors.accentBlue)
                            .monospacedDigit()
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    Text("\(displayRemainingCount)")
                        .zTransferTypography(.labelLarge, weight: .bold)
                        .foregroundStyle(ZTransferColors.primaryText)
                        .monospacedDigit()
                        .id(displayRemainingCount)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
        }
        // Keep the horizontal inset in the same coordinate space as the
        // liquid layer. The outer Button used to add this padding after
        // QueuePill had measured itself, leaving the fill visibly inset from
        // the glass capsule and offsetting the 100% edge.
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background {
            if let activeItem, snapshot.isTransferring {
                LiquidTransferProgressFill(
                    progress: activeProgress?.taskID == activeItem.id
                        ? activeProgress!.fraction
                        : activeItem.progress,
                    seed: activeItem.id.uuidString,
                    isCapsule: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(Capsule())
                .transition(.opacity)
            }
        }
        .clipShape(Capsule())
        .scaleEffect(impactScale ? 1.10 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: impactScale)
        .animation(ZTransferMotion.standard, value: displayRemainingCount)
        .animation(ZTransferMotion.standard, value: generationCount)
        .animation(ZTransferMotion.standard, value: showDoneLabel)
        .onChange(of: hasActive) { active in
            if active {
                sawActiveBatch = true
                doneTask?.cancel()
                showDoneLabel = false
            }
        }
        .onChange(of: impact) { _ in
            impactScale = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                impactScale = false
            }
        }
        .task(id: "\(hasActive)-\(paused)-\(displayRemainingCount)") {
            if paused || hasActive {
                countingVisible = true
            } else if displayRemainingCount > 0 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                countingVisible = true
            } else {
                countingVisible = false
            }
        }
        .onChange(of: allDone) { done in
            guard let previousAllDone else {
                self.previousAllDone = done
                return
            }
            if done && !previousAllDone {
                if !hasCancelled {
                    withAnimation(ZTransferMotion.standard) { showDoneLabel = true }
                    doneTask?.cancel()
                    doneTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(ZTransferMotion.standard) { showDoneLabel = false }
                    }
                }
                sawActiveBatch = false
            }
            self.previousAllDone = done
        }
        .onAppear { previousAllDone = allDone }
        .onDisappear { doneTask?.cancel() }
    }

    private func speedText(_ bytesPerSecond: Int64) -> String {
        switch bytesPerSecond {
        case ..<1024: return "\(bytesPerSecond) B/s"
        case ..<(1024 * 1024): return String(format: "%.1f KB/s", Double(bytesPerSecond) / 1024)
        default: return String(format: "%.1f MB/s", Double(bytesPerSecond) / (1024 * 1024))
        }
    }
}

private struct CameraThumbnailView: View {
    let session: CameraSession
    let handle: UInt32
    var file: CameraFile?
    var transferred: Bool = false
    var inBurst: Bool = false
    var queueTask: TransferQueueItem? = nil
    var liveProgress: TransferActiveProgress? = nil
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else { RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)).overlay { ProgressView() } }
            }
            if let file {
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
                    TransferStatusBadge(status: task.status, progress: liveProgress?.taskID == task.id ? liveProgress!.fraction : task.progress, taskID: task.id)
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
        .task {
            guard image == nil else { return }
            if let file, let data = try? await session.thumbnail(file: file), let image = UIImage(data: data) {
                self.image = image
            } else if file == nil, let data = try? await session.thumbnail(handle: handle), let image = UIImage(data: data) {
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
                    CameraThumbnailView(session: session, handle: item.element.id, file: item.element)
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
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
        }.buttonStyle(.plain)
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
            .background(.thinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
            .animation(.easeInOut(duration: 0.24), value: expanded)
        }.buttonStyle(.plain)
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
