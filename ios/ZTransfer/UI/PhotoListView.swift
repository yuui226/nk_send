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

struct PhotoListView: View {
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
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: min(max(thumbnailColumns, 2), 5))
    }

    var body: some View {
        ZStack {
            ZTransferColors.background.ignoresSafeArea()
            if showingQueue {
                TransferQueueView(model: queueModel, session: session, directory: directoryStore) {
                    withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.22)) {
                        showingQueue = false
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
            ScrollViewReader { reader in
                ScrollView {
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
                        ForEach(model.sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
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
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                if !collapsedDays.contains(section.day) { LazyVGrid(columns: columns, spacing: 8) {
                                        ForEach(photoGridEntries(section.files, collapse: collapseBurstPhotos, expandedIDs: expandedBurstIDs)) { entry in
                                        let file = entry.firstFile
                                        VStack(alignment: .leading, spacing: 0) {
                                            if let session {
                                                if case let .burst(group) = entry { BurstThumbnailView(session: session, group: group) }
                                                else { CameraThumbnailView(session: session, handle: file.id, file: file) }
                                                } else { PlaceholderThumbnail() }
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { handleTap(entry, file: file) }
                                        .onLongPressGesture { if !tapToPreview { selectedFile = file } }
                                    }
                                } }
                            }
                        }
                    }
                    }.padding(.horizontal, ZTransferMetrics.pageHorizontal).padding(.top, 62)
                }
                .coordinateSpace(name: "photo-list-scroll")
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
                .overlay(alignment: .top) {
                    // Android's FileListScreen places this floating row inside
                    // statusBarsPadding().  The list itself is edge-to-edge,
                    // so the inset must be applied to the overlay rather than
                    // consuming list content height.
                    GeometryReader { proxy in
                        photoListTopControls
                            .padding(.top, proxy.safeAreaInsets.top)
                    }
                }
            }
            }
        }
        .task {
            if let session {
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
        }
        .onChange(of: queueModel.snapshot.items) { items in
            model.updateTransferredIDs(Set(items.filter { $0.status == .completed }.map { $0.file.id }))
            // Android clears the persisted transfer directory as soon as the
            // queue proves its handle stale. Keep the scene's directory store
            // in the same state so a retry opens the existing chooser flow.
            if items.contains(where: { $0.status == .failed && $0.error == AppLocalized.resource("error_dir_invalid") }) {
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
        .fullScreenCover(item: $selectedFile) { file in
            if let session {
                let files = model.sections.flatMap(\.files)
                PhotoPreviewView(session: session, files: files, selectedFile: $selectedFile,
                                 directory: directoryStore.directoryURL,
                                 organizeByDate: organizeByDate) { file in
                    if !deferTransferStart {
                        queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL, organizeByDate: organizeByDate, effects: effectsStore.settings)
                    } else {
                        queueModel.enqueue(file, organizeByDate: organizeByDate, effects: effectsStore.settings)
                    }
                }
                .onAppear { model.pauseForPreview() }
                .onDisappear {
                    model.resumeAfterPreview()
                    model.wakeThumbnailFill()
                }
            }
        }
        .fullScreenCover(isPresented: $showingRemote) {
            if let session {
                RemoteView(session: session).onDisappear {
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
                        .frame(height: 36)
                    }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))

                    Button { showingFilter = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 36, height: 36)
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

            if queueModel.snapshot.isTransferring {
                Button { queueModel.pause() } label: {
                    Image(systemName: "pause.fill").frame(width: 36, height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
            } else if queueModel.snapshot.items.contains(where: { $0.status == .waiting }),
                      let session, let directory = directoryStore.directoryURL {
                Button { queueModel.start(session: session, directory: directory) } label: {
                    Image(systemName: "play.fill").frame(width: 36, height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
            }

            if !queueModel.snapshot.items.isEmpty {
                Button {
                    withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.22)) {
                        showingQueue = true
                    }
                } label: {
                    QueuePill(snapshot: queueModel.snapshot)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .animation(ZTransferMotion.standard, value: queueModel.snapshot.items.count)
        .onPreferenceChange(PhotoListSettingsAnchorPreferenceKey.self) { settingsAnchor = $0 }
        .onPreferenceChange(PhotoListFilterAnchorPreferenceKey.self) { filterAnchor = $0 }
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

    private func handleTap(_ entry: PhotoGridEntry, file: CameraFile) {
        if case let .burst(group) = entry {
            let shouldExpand = collapseBurstPhotos && !expandedBurstIDs.contains(group.id)
            if shouldExpand {
                _ = withAnimation(ZTransferMotion.standard) { expandedBurstIDs.insert(group.id) }
                return
            }
        }
        if tapToPreview {
            selectedFile = file
        } else if !deferTransferStart {
            queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL, organizeByDate: organizeByDate, effects: effectsStore.settings)
        } else {
            queueModel.enqueue(file, organizeByDate: organizeByDate, effects: effectsStore.settings)
        }
    }
}

/// The Android SignalPill has a dedicated USB mark and a four-bar STA mark.
/// AP has no public RSSI API on iOS, so it retains the existing Wi-Fi glyph
/// until a platform-equivalent signal value is available; no synthetic level
/// is introduced.
private struct PhotoListSignalIcon: View {
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

private func photoGridEntries(_ files: [CameraFile], collapse: Bool = true, expandedIDs: Set<String> = []) -> [PhotoGridEntry] {
    guard collapse else { return files.map(PhotoGridEntry.photo) }
    let groups = PhotoCatalogGrouping.bursts(in: files)
    let groupedIDs = groups.reduce(into: Set<UInt32>()) { result, group in result.formUnion(group.files.map(\.id)) }
    let byFirstID = Dictionary(uniqueKeysWithValues: groups.compactMap { group in group.files.first.map { ($0.id, group) } })
    var entries: [PhotoGridEntry] = []
    for file in files {
        if let group = byFirstID[file.id] {
            if expandedIDs.contains(group.id) {
                entries.append(contentsOf: group.files.map(PhotoGridEntry.photo))
            } else {
                entries.append(.burst(group))
            }
        }
        else if !groupedIDs.contains(file.id) { entries.append(.photo(file)) }
    }
    return entries
}

private struct QueuePill: View {
    let snapshot: TransferQueueSnapshot
    private var remainingCount: Int {
        snapshot.items.reduce(into: 0) { count, item in
            if item.status == .waiting || item.status == .transferring || item.isGeneratingFrame {
                count += 1
            }
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.isTransferring ? "arrow.down.circle.fill" : "checklist")
                .scaleEffect(remainingCount > 0 ? 1 : 0.9)
            if remainingCount > 0 {
                Text("\(remainingCount)")
                    .monospacedDigit()
                    .id(remainingCount)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .animation(ZTransferMotion.standard, value: remainingCount)
    }
}

private struct CameraThumbnailView: View {
    let session: CameraSession
    let handle: UInt32
    var file: CameraFile?
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)).overlay { ProgressView() } }
            }
            if let file {
                if !file.fileExtension.isEmpty {
                    Text(file.fileExtension.dropFirst().uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(extensionColor(file.fileExtension), in: RoundedRectangle(cornerRadius: 6))
                }
                if file.isProtected {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(4)
                        .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
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
        switch ext {
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
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CameraThumbnailView(session: session, handle: group.files[0].id, file: group.files[0])
            Text("\(group.files.count)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.62), in: Capsule()).padding(6)
        }
    }
}
