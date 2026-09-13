import SwiftUI
import UIKit

struct PhotoListView: View {
    @StateObject private var model: PhotoListViewModel
    @StateObject private var queueModel: TransferQueueViewModel
    @ObservedObject private var directoryStore: DirectoryAccessStore
    let onDisconnect: () -> Void
    private let session: CameraSession?
    @AppStorage("tapToPreview") private var tapToPreview = false
    @State private var selectedFile: CameraFile?
    @State private var showingFilter = false
    @State private var showingQueue = false
    @AppStorage("deferTransferStart") private var deferTransferStart = false
    @AppStorage("collapseBurstPhotos") private var collapseBurstPhotos = false
    @AppStorage("thumbnailColumns") private var thumbnailColumns = 3
    @State private var expandedBurstIDs: Set<String> = []
    @State private var collapsedDays: Set<String> = []
    @State private var showTopButton = false
    @State private var showingRemote = false

    init(repository: CameraRepository, queue: TransferQueue = TransferQueue(), directory: DirectoryAccessStore = DirectoryAccessStore(), onDisconnect: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PhotoListViewModel(repository: repository))
        _queueModel = StateObject(wrappedValue: TransferQueueViewModel(queue: queue))
        _directoryStore = ObservedObject(wrappedValue: directory)
        self.onDisconnect = onDisconnect; self.session = nil
    }

    init(session: CameraSession, queue: TransferQueue, directory: DirectoryAccessStore = DirectoryAccessStore(), onDisconnect: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PhotoListViewModel(session: session))
        _queueModel = StateObject(wrappedValue: TransferQueueViewModel(queue: queue))
        _directoryStore = ObservedObject(wrappedValue: directory)
        self.onDisconnect = onDisconnect; self.session = session
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: min(max(thumbnailColumns, 2), 5))
    }

    var body: some View {
        ZStack {
            ZTransferColors.background.ignoresSafeArea()
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
                                        Text(section.day == "__unknown__" ? "未知日期" : section.day)
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
                    }.padding(.horizontal, ZTransferMetrics.pageHorizontal).padding(.top, 20)
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
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(action: onDisconnect) { Image(systemName: "chevron.left") } }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                if !queueModel.snapshot.items.isEmpty {
                    Button { showingQueue = true } label: { QueuePill(snapshot: queueModel.snapshot) }
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .task { model.load() }
        .task {
            if let session, let directory = directoryStore.directoryURL { queueModel.start(session: session, directory: directory) }
        }
        .onChange(of: collapseBurstPhotos) { enabled in
            if !enabled { expandedBurstIDs.removeAll() }
        }
        .onChange(of: model.sections) { sections in
            let valid = Set(sections.map(\.day))
            collapsedDays = collapsedDays.intersection(valid)
        }
        .onChange(of: queueModel.snapshot.items) { items in
            model.updateTransferredIDs(Set(items.filter { $0.status == .completed }.map { $0.file.id }))
        }
        .fullScreenCover(item: $selectedFile) { file in
            if let session {
                let files = model.sections.flatMap(\.files)
                PhotoPreviewView(session: session, files: files, selectedFile: $selectedFile) { file in
                    if !deferTransferStart {
                        queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL)
                    } else {
                        queueModel.enqueue(file)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingRemote) {
            if let session { RemoteView(session: session) }
        }
        .sheet(isPresented: $showingFilter) {
            let files = model.availableFiles
            let extensions = Array(Set(files.map(\.fileExtension))).sorted()
            let slots = Array(Set(files.map(\.storageID))).sorted()
            PhotoFilterSheet(initial: model.filter,
                             availableExtensions: extensions.isEmpty ? [".jpg", ".nef", ".mp4"] : extensions,
                             availableStorageSlots: slots,
                             onApply: { model.setFilter($0); showingFilter = false })
        }
        .sheet(isPresented: $showingQueue) {
            TransferQueueView(model: queueModel, session: session, directory: directoryStore)
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
            queueModel.enqueue(file, autoStart: session, directory: directoryStore.directoryURL)
        } else {
            queueModel.enqueue(file)
        }
    }
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
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.isTransferring ? "arrow.down.circle.fill" : "checklist")
                .scaleEffect(snapshot.items.count > 0 ? 1 : 0.9)
            Text("\(snapshot.items.count)")
                .monospacedDigit()
                .id(snapshot.items.count)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
        }
        .animation(ZTransferMotion.standard, value: snapshot.items.count)
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
            if let data = try? await session.thumbnail(handle: handle), let image = UIImage(data: data) { self.image = image }
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
