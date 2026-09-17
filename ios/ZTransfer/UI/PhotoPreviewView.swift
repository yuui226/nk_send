import SwiftUI
import UIKit

@preconcurrency
struct PhotoPreviewAnchorTransform: AnimatableModifier {
    var progress: CGFloat
    let anchor: CGRect?
    let enabled: Bool
    let closing: Bool

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let viewport = UIScreen.main.bounds
        let validAnchor = anchor.flatMap { rect in
            rect.width > 0 && rect.height > 0 && viewport.width > 0 && viewport.height > 0 ? rect : nil
        }
        let shouldAnchor = enabled && validAnchor != nil
        let startScale = validAnchor.map { min(max($0.width / viewport.width, 0.05), 1) } ?? 1
        let scale = shouldAnchor ? startScale + (1 - startScale) * progress : 1
        let origin = validAnchor.map {
            UnitPoint(
                x: min(max(($0.midX - viewport.minX) / viewport.width, 0), 1),
                y: min(max(($0.midY - viewport.minY) / viewport.height, 0), 1)
            )
        } ?? .center
        content
            .scaleEffect(scale, anchor: origin)
            .opacity(shouldAnchor ? (closing ? min(progress * 1.6, 1) : 1) : progress)
    }
}

enum LocalOriginalPreviewRoute: Equatable {
    case directBitmap
    case rawEmbeddedJPEG
    case cameraFHD
}

private let videoFourGiB = UInt64(4) * 1024 * 1024 * 1024

func formatPreviewCaptureDate(_ raw: String?) -> String? {
    guard let raw, raw.count >= 8, raw.prefix(8).allSatisfy(\.isNumber),
          let year = Int(raw.prefix(4)),
          let month = Int(raw.dropFirst(4).prefix(2)),
          let day = Int(raw.dropFirst(6).prefix(2)) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let dateValue = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
        return nil
    }
    let resolved = calendar.dateComponents([.year, .month, .day], from: dateValue)
    guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
    let date = String(format: "%04d-%02d-%02d", year, month, day)
    guard raw.count >= 15, raw.dropFirst(8).first == "T",
          raw.dropFirst(9).prefix(6).allSatisfy(\.isNumber),
          let hour = Int(raw.dropFirst(9).prefix(2)),
          let minute = Int(raw.dropFirst(11).prefix(2)),
          let second = Int(raw.dropFirst(13).prefix(2)),
          (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
        return date
    }
    return date + String(format: " %02d:%02d:%02d", hour, minute, second)
}

private func videoPreviewMetadata(file: CameraFile) -> String {
    var values: [String] = []
    if file.size == UInt64(UInt32.max) || file.size > videoFourGiB {
        values.append(AppLocalized.resource("video_size_over_4gb"))
    } else if file.size > 0 {
        let bytes = file.size
        if bytes < 1024 { values.append("\(bytes) B") }
        else if bytes < 1024 * 1024 { values.append("\(bytes / 1024) KB") }
        else if bytes < 1024 * 1024 * 1024 {
            values.append(String(format: "%.1f MB", Double(bytes) / (1024 * 1024)))
        } else {
            values.append(String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024)))
        }
    }
    if let date = formatPreviewCaptureDate(file.captureDate) { values.append(date) }
    return values.joined(separator: "  ·  ")
}

func localOriginalPreviewRoute(for fileExtension: String) -> LocalOriginalPreviewRoute {
    switch fileExtension.lowercased() {
    case ".nef", ".nrw": return .rawEmbeddedJPEG
    case ".tif", ".tiff": return .cameraFHD
    case ".mov", ".mp4", ".avi": return .cameraFHD
    default: return .directBitmap
    }
}

private func decodeLocalOriginalPreview(at url: URL, route: LocalOriginalPreviewRoute) -> UIImage? {
    switch route {
    case .cameraFHD:
        return nil
    case .directBitmap:
        return UIImage(contentsOfFile: url.path)
    case .rawEmbeddedJPEG:
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary
              ) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct PhotoPreviewView: View {
    @ObservedObject var queueModel: TransferQueueViewModel
    let session: CameraSession
    let files: [CameraFile]
    let burstGroups: [BurstPhotoGroup]
    let burstIDByFile: [UInt32: String]
    let transferredFileIDs: Set<UInt32>
    let queueTarget: CGRect?
    let directory: URL?
    let organizeByDate: Bool
    @Binding var selectedFile: CameraFile?
    /// Returns false when the Android preflight (directory/connection gate)
    /// rejects the task. The queue flight must not play without a real task.
    let onEnqueue: (CameraFile) -> Bool
    let onEnqueueBurst: ([CameraFile]) -> Bool
    let onBurstChanged: (String, Bool) -> Void
    let onQueueFlightStarted: (Int) -> Void
    let onQueueFlightFinished: (Int) -> Void
    let initialAnchor: CGRect?
    let prepareDismissTarget: (CameraFile) async -> CGRect?
    let onDismiss: (CameraFile?) -> Void
    private let initialIndex: Int
    @State private var index: Int
    @State private var previewEntries: [PhotoPreviewEntry]
    @State private var rotationDegrees: Double = 0
    @AppStorage("preview_rotation_quarter_turns") private var rotationQuarterTurns = 0
    @State private var exif: PhotoExif?
    @State private var exifLoading = false
    // Android persists this switch in the transfer preference store, so it
    // survives leaving the preview and reopening the app.
    @AppStorage("preview_histogram_enabled") private var histogramVisible = false
    @State private var histogramBars: [CGFloat] = []
    // The preview page publishes the bitmap it is already displaying. Keep
    // that reference so enabling the histogram never starts another camera
    // read or decodes the same image a second time.
    @State private var displayedImages: [UInt32: UIImage] = [:]
    @State private var highResolutionImages: [UInt32: UIImage] = [:]
    @State private var highResolutionLoading: Set<UInt32> = []
    @State private var localHighResolutionSources: [UInt32: URL] = [:]
    @State private var localDecodeFailures: [UInt32: URL] = [:]
    @State private var fhdUnavailable: Set<UInt32> = []
    @State private var exifByFile: [UInt32: PhotoExif] = [:]
    @State private var exifFinished: Set<UInt32> = []
    @State private var deferredLoadsEnabled = false
    @State private var previousTransfersBusy = false
    @State private var neighborPrefetchTask: Task<Void, Never>?
    @State private var queueDragOffset: CGFloat = 0
    @State private var currentZoomed = false
    @State private var queueFlightTask: Task<Void, Never>?
    @State private var queueFlightActive = false
    @State private var queueFlightProgress: CGFloat = 0
    @State private var queueFlightImage: UIImage?
    @State private var queueFlightImages: [UIImage?] = []
    @State private var queueFlightCount = 0
    @State private var expandedBurstIDs: Set<String> = []
    @State private var presentationProgress: CGFloat = 0
    @State private var closing = false
    @State private var collapseAnchor: CGRect?
    @State private var burstTransitionBusy = false
    @State private var burstTransitionTask: Task<Void, Never>?
    @State private var animatedBurstID: String?
    @State private var burstStackMotion: CGFloat = 0
    @State private var burstPagerScale: CGFloat = 1
    @State private var burstPagerAlpha: CGFloat = 1
    @State private var burstPagerSlide: CGFloat = 0
    /// Android snapshots already-exported originals when the preview overlay
    /// opens; a transfer completing underneath must not replace the source of
    /// the current page halfway through its load.
    @State private var localOriginalURLs: [UInt32: URL]

    init(session: CameraSession, queueModel: TransferQueueViewModel, files: [CameraFile],
         burstIDByFile: [UInt32: String] = [:], transferredFileIDs: Set<UInt32> = [],
         selectedFile: Binding<CameraFile?>,
         directory: URL? = nil, organizeByDate: Bool = false,
         queueTarget: CGRect? = nil,
         initialAnchor: CGRect? = nil,
         initialExpandedBurstIDs: Set<String> = [],
         collapseBursts: Bool = true,
         onBurstChanged: @escaping (String, Bool) -> Void = { _, _ in },
         onEnqueue: @escaping (CameraFile) -> Bool = { _ in false },
         onEnqueueBurst: @escaping ([CameraFile]) -> Bool = { _ in false },
         onQueueFlightStarted: @escaping (Int) -> Void = { _ in },
         onQueueFlightFinished: @escaping (Int) -> Void = { _ in },
         prepareDismissTarget: @escaping (CameraFile) async -> CGRect? = { _ in nil },
         onDismiss: @escaping (CameraFile?) -> Void = { _ in }) {
        self.queueModel = queueModel
        self.session = session; self.files = files; self.directory = directory
        self.burstGroups = PhotoCatalogGrouping.bursts(in: files)
        self.burstIDByFile = burstIDByFile
        self.transferredFileIDs = transferredFileIDs
        self.queueTarget = queueTarget
        self.initialAnchor = initialAnchor
        self.organizeByDate = organizeByDate; _selectedFile = selectedFile
        self.onEnqueue = onEnqueue; self.onEnqueueBurst = onEnqueueBurst
        self.onQueueFlightStarted = onQueueFlightStarted
        self.onQueueFlightFinished = onQueueFlightFinished
        self.onBurstChanged = onBurstChanged
        self.prepareDismissTarget = prepareDismissTarget
        self.onDismiss = onDismiss
        var entries = collapseBursts ? collapsedPhotoPreviewEntries(files: files, burstIDByFile: burstIDByFile)
                                     : files.map { PhotoPreviewEntry.photo($0, burstID: burstIDByFile[$0.id]) }
        for position in entries.indices.reversed() {
            if case .burst(let group) = entries[position], initialExpandedBurstIDs.contains(group.id) {
                entries = expandPhotoPreviewBurst(entries, at: position)
            }
        }
        _expandedBurstIDs = State(initialValue: initialExpandedBurstIDs)
        let first = selectedFile.wrappedValue ?? files.first
        let initialIndex = first.flatMap { selected in
            entries.firstIndex { entry in
                switch entry {
                case .photo(let file, _): return file.id == selected.id
                case .burst: return false
                }
            }
        } ?? 0
        self.initialIndex = initialIndex
        _previewEntries = State(initialValue: entries)
        _index = State(initialValue: initialIndex)
        _collapseAnchor = State(initialValue: initialAnchor)
        var sources: [UInt32: URL] = [:]
        if let directory {
            for file in files {
                guard localOriginalPreviewRoute(for: file.fileExtension) != .cameraFHD else { continue }
                let destination = transferDestinationDirectory(
                    root: directory,
                    folderName: organizeByDate ? transferDateFolderName(file.captureDate) : nil
                )
                if let original = existingTransferDestination(for: file, in: destination) {
                    sources[file.id] = original
                }
            }
        }
        _localOriginalURLs = State(initialValue: sources)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.74 * presentationProgress).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(previewEntries.enumerated()), id: \.element.id) { itemIndex, entry in
                    Group {
                        switch entry {
                        case .photo(let file, _):
                            PreviewImage(session: session, file: file,
                                         highResolutionImage: highResolutionImages[file.id],
                                         rotationDegrees: rotationDegrees,
                                         zoomEnabled: !file.fileExtension.lowercased().hasSuffix(".mov") &&
                                            !file.fileExtension.lowercased().hasSuffix(".mp4"),
                                         allowRemoteThumbnailFallback: fhdUnavailable.contains(file.id) &&
                                            exifFinished.contains(file.id),
                                         onDisplayImage: { image in
                                             let retained = retainedPhotoPreviewIDs(
                                                entries: previewEntries, currentIndex: index
                                             )
                                             if retained.contains(file.id) { displayedImages[file.id] = image }
                                             guard histogramVisible, currentPhoto?.id == file.id else { return }
                                             histogramBars = image.map(luminanceHistogram) ?? []
                                         }, onTap: startClose,
                                         onZoomedChange: { zoomed in if index == itemIndex { currentZoomed = zoomed } },
                                         isCurrent: index == itemIndex)
                        case .burst(let group):
                            BurstCollectionPreview(
                                session: session,
                                group: group,
                                stackMotion: animatedBurstID == group.id ? burstStackMotion : 0,
                                onTap: startClose
                            )
                        }
                    }
                        .tag(itemIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .modifier(PhotoPreviewAnchorTransform(
                progress: presentationProgress,
                anchor: closing ? collapseAnchor : initialAnchor,
                enabled: closing ? collapseAnchor != nil : index == initialIndex,
                closing: closing
            ))
            .scaleEffect(burstPagerScale)
            .opacity(burstPagerAlpha)
            .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
            .offset(y: queueDragOffset)
            .allowsHitTesting(!queueFlightActive && !closing && !burstTransitionBusy)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard !queueFlightActive else { return }
                        let translation = value.translation
                        guard currentPhoto != nil, !currentZoomed, !queueFlightActive, translation.height < 0,
                              -translation.height >= abs(translation.width) * 1.15 else {
                            return
                        }
                        queueDragOffset = max(-180, translation.height)
                    }
                    .onEnded { value in
                        guard !currentZoomed, !queueFlightActive,
                              previewEntries.indices.contains(index) else { return }
                        let translation = value.translation
                        guard translation.height < 0,
                              -translation.height >= 96,
                              -translation.height >= abs(translation.width) * 1.15 else {
                            withAnimation(ZTransferMotion.standard) { queueDragOffset = 0 }
                            return
                        }
                        if let file = currentPhoto { startQueueFlight(for: file) }
                    }
            )
            if queueFlightActive, let queueTarget, previewEntries.indices.contains(index) {
                GeometryReader { proxy in
                    PhotoPreviewQueueFlightView(
                        progress: queueFlightProgress,
                        image: queueFlightImage,
                        images: queueFlightImages,
                        from: CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.46),
                        target: CGPoint(
                            x: queueTarget.midX - proxy.frame(in: .global).minX,
                            y: queueTarget.midY - proxy.frame(in: .global).minY
                        ),
                        size: CGSize(width: proxy.size.width * 0.72, height: proxy.size.height * 0.52),
                        stackCount: queueFlightCount
                    )
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }
            if let exif, currentPhoto != nil {
                PreviewExifBar(exif: exif)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 12).padding(.bottom, 24)
            }
            if let file = currentPhoto {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("\(index + 1)/\(previewEntries.count) · \(file.fileName)")
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.5).allowsTightening(true)
                        if let task = queueModel.task(for: file.id), task.status != .completed {
                            TransferStatusBadge(status: task.status,
                                progress: queueModel.activeProgress?.taskID == task.id ? queueModel.activeProgress!.fraction : task.progress,
                                taskID: task.id)
                        } else if transferredOriginal(file) { TransferredPhotoBadge() }
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(height: 36)
                    if burstIDByFile[file.id] != nil || file.isProtected {
                        HStack(spacing: 8) {
                            if burstIDByFile[file.id] != nil {
                                Label(AppLocalized.resource("burst_label"), systemImage: "square.on.square")
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.teal.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
                            }
                            if file.isProtected {
                                Label(AppLocalized.resource("filter_protected"), systemImage: "key.fill")
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.22), lineWidth: 1))
                            }
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    }
                }
                .padding(.top, 6).padding(.leading, 12).padding(.trailing, 184)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let file = currentPhoto {
                VStack(spacing: 12) {
                    if photoPreviewCollectionIndex(previewEntries, memberIndex: index) != nil {
                        PreviewCircleButton(symbol: "chevron.left", accessibilityKey: "cd_collapse") {
                            collapseCurrentBurst()
                        }
                    }
                    if !isVideo(file) {
                        PreviewCircleButton(symbol: "chart.bar.fill", accessibilityKey: "cd_preview_histogram", active: histogramVisible) {
                            histogramVisible.toggle()
                        }
                        PreviewCircleButton(symbol: "rotate.left", accessibilityKey: "cd_rotate_photo") {
                            rotationDegrees -= 90
                            rotationQuarterTurns = ((Int(-rotationDegrees / 90) % 4) + 4) % 4
                        }
                    }
                    PreviewCircleButton(symbol: "plus", accessibilityKey: "cd_transfer") { startQueueFlight(for: file) }
                }
                .padding(.trailing, 20).padding(.bottom, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            } else if previewEntries.indices.contains(index), case let .burst(group) = previewEntries[index] {
                HStack(spacing: 22) {
                    PreviewCircleButton(symbol: "plus", accessibilityKey: "cd_transfer_group", size: 48) {
                        if let first = group.files.first { startQueueFlight(for: first, burstFiles: group.files) }
                    }
                    PreviewCircleButton(symbol: "chevron.right", accessibilityKey: "cd_expand") { expandBurst(group) }
                }
                .padding(.bottom, 112)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            if histogramVisible, !histogramBars.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(histogramBars.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.48)).frame(width: 3, height: max(2, value * 34))
                    }
                }
                .frame(width: 110, height: 48, alignment: .bottom)
                .padding(8)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity)
                .padding(.leading, 20).padding(.bottom, 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(!burstTransitionBusy && !closing)
        .onAppear {
            rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
            rotationDegrees = -90 * Double(rotationQuarterTurns)
            previousTransfersBusy = queueModel.snapshot.isTransferring
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.34)) {
                presentationProgress = 1
            }
        }
        .onDisappear {
            burstTransitionTask?.cancel()
            burstTransitionTask = nil
            neighborPrefetchTask?.cancel()
            neighborPrefetchTask = nil
            queueFlightTask?.cancel()
            queueFlightTask = nil
            if queueFlightCount > 0 { onQueueFlightFinished(queueFlightCount) }
            queueFlightCount = 0
            queueFlightProgress = 0
            queueFlightImage = nil
            queueFlightImages = []
        }
        .onChange(of: index) { value in
            if previewEntries.indices.contains(value) {
                selectedFile = previewEntries[value].file ?? {
                    if case .burst(let group) = previewEntries[value] { return group.files.first }
                    return nil
                }()
                exif = nil
                exifLoading = false
                currentZoomed = false
                trimPreviewState()
            }
        }
        .onChange(of: queueModel.snapshot.isTransferring) { busy in
            let shouldResumePrefetch = previousTransfersBusy && !busy
            previousTransfersBusy = busy
            guard shouldResumePrefetch, deferredLoadsEnabled else { return }
            neighborPrefetchTask?.cancel()
            let currentIndex = index
            neighborPrefetchTask = Task { await prefetchNeighbors(around: currentIndex, allowCameraRequest: true) }
        }
        .onChange(of: histogramVisible) { visible in
            guard visible, let file = currentPhoto,
                  let image = displayedImages[file.id] else { return }
            histogramBars = luminanceHistogram(image)
        }
        .task {
            await session.setFHDActive(true)
            do {
                try await Task.sleep(nanoseconds: 340_000_000)
                guard !Task.isCancelled else { throw CancellationError() }
                deferredLoadsEnabled = true
                try await Task.sleep(nanoseconds: .max)
            } catch {}
            await session.setFHDActive(false)
        }
        .task(id: previewLoadIdentity) {
            guard deferredLoadsEnabled else { return }
            await loadCurrentThenNeighbors()
        }
    }

    private var currentPhoto: CameraFile? {
        guard previewEntries.indices.contains(index) else { return nil }
        return previewEntries[index].file
    }

    private func startClose() {
        guard !closing, !burstTransitionBusy else { return }
        closing = true
        queueFlightTask?.cancel()
        queueFlightTask = nil
        let returnFile = currentPhoto
        Task { @MainActor in
            collapseAnchor = if let returnFile {
                await prepareDismissTarget(returnFile)
            } else {
                nil
            }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) {
                presentationProgress = 0
            }
            try? await Task.sleep(nanoseconds: 260_000_000)
            onDismiss(collapseAnchor == nil ? nil : returnFile)
        }
    }

    private var previewLoadIdentity: String {
        let entryID = previewEntries.indices.contains(index) ? previewEntries[index].id : "none"
        return "\(entryID)|\(deferredLoadsEnabled)"
    }

    @MainActor
    private func loadCurrentThenNeighbors() async {
        trimPreviewState()
        guard let file = currentPhoto else {
            exif = nil
            histogramBars = []
            return
        }
        histogramBars = []
        exif = exifByFile[file.id]
        exifLoading = !exifFinished.contains(file.id)

        let loadedLocally = await loadHighResolution(
            at: index, awaitExisting: true, allowCameraRequest: false
        )
        guard !Task.isCancelled else { return }
        if loadedLocally { ZTransferHaptics.shared.tick() }

        let localResolved = localOriginalURLs[file.id].map {
            localHighResolutionSources[file.id] == $0
        } ?? false
        if localResolved {
            await loadLocalExif(file: file)
        } else {
            let needsPreview = !isVideo(file) && highResolutionImages[file.id] == nil
            highResolutionLoading.insert(file.id)
            defer { highResolutionLoading.remove(file.id) }
            let (data, metadata) = await session.previewAndExif(file: file, loadPreview: needsPreview)
            guard !Task.isCancelled else { return }
            finishRemoteCurrentLoad(file: file, data: data, metadata: metadata)
        }
        guard !Task.isCancelled else { return }
        await prefetchNeighbors(around: index, allowCameraRequest: !queueModel.snapshot.isTransferring)
    }

    @MainActor
    private func loadHighResolution(
        at page: Int,
        awaitExisting: Bool = false,
        allowCameraRequest: Bool
    ) async -> Bool {
        guard previewEntries.indices.contains(page), let file = previewEntries[page].file else { return false }
        let id = file.id
        if isVideo(file) {
            fhdUnavailable.insert(id)
            return false
        }
        if let existing = highResolutionImages[id] {
            if let source = localHighResolutionSources[id], source != localOriginalURLs[id] {
                highResolutionImages.removeValue(forKey: id)
                displayedImages.removeValue(forKey: id)
                localHighResolutionSources.removeValue(forKey: id)
            } else {
                _ = existing
                fhdUnavailable.remove(id)
                return false
            }
        }
        if highResolutionLoading.contains(id) {
            guard awaitExisting else { return false }
            // Android waits when a former neighbor becomes the current page.
            // The old task may be finishing or unwinding cancellation; do not
            // start a duplicate FHD request or clear its loading ownership.
            while highResolutionLoading.contains(id), highResolutionImages[id] == nil {
                do { try await Task.sleep(nanoseconds: 16_000_000) }
                catch { return false }
            }
            if highResolutionImages[id] != nil { return false }
        }
        highResolutionLoading.insert(id)
        defer { highResolutionLoading.remove(id) }

        if let source = localOriginalURLs[id],
           localOriginalPreviewRoute(for: file.fileExtension) != .cameraFHD,
           localDecodeFailures[id] != source {
            let route = localOriginalPreviewRoute(for: file.fileExtension)
            let localImage = await Task.detached(priority: .userInitiated) {
                decodeLocalOriginalPreview(at: source, route: route)
            }.value
            guard !Task.isCancelled else { return false }
            if let localImage {
                highResolutionImages[id] = localImage
                displayedImages[id] = localImage
                localHighResolutionSources[id] = source
                localDecodeFailures.removeValue(forKey: id)
                fhdUnavailable.remove(id)
                return true
            }
            localDecodeFailures[id] = source
        }
        guard allowCameraRequest, !Task.isCancelled else { return false }
        guard let data = try? await session.preview(handle: id),
              !Task.isCancelled,
              let image = UIImage(data: data) else {
            if !Task.isCancelled { fhdUnavailable.insert(id) }
            return false
        }
        highResolutionImages[id] = image
        displayedImages[id] = image
        localHighResolutionSources.removeValue(forKey: id)
        fhdUnavailable.remove(id)
        return true
    }

    @MainActor
    private func loadLocalExif(file: CameraFile) async {
        guard !exifFinished.contains(file.id) else {
            exif = exifByFile[file.id]
            exifLoading = false
            return
        }
        let metadata: PhotoExif?
        if let source = localOriginalURLs[file.id], let data = try? Data(contentsOf: source) {
            metadata = PhotoExifParser.parse(data)
        } else {
            metadata = nil
        }
        guard !Task.isCancelled else { return }
        if let metadata { exifByFile[file.id] = metadata }
        exifFinished.insert(file.id)
        if currentPhoto?.id == file.id {
            exif = metadata
            exifLoading = false
        }
    }

    @MainActor
    private func finishRemoteCurrentLoad(file: CameraFile, data: Data?, metadata: PhotoExif?) {
        if let data, let image = UIImage(data: data) {
            highResolutionImages[file.id] = image
            displayedImages[file.id] = image
            localHighResolutionSources.removeValue(forKey: file.id)
            fhdUnavailable.remove(file.id)
            ZTransferHaptics.shared.tick()
        } else {
            fhdUnavailable.insert(file.id)
        }
        if let metadata { exifByFile[file.id] = metadata }
        exifFinished.insert(file.id)
        if currentPhoto?.id == file.id {
            exif = metadata
            exifLoading = false
        }
    }

    @MainActor
    private func prefetchNeighbors(around page: Int, allowCameraRequest: Bool) async {
        for neighbor in neighboringPhotoPreviewIndices(entries: previewEntries, currentIndex: page) {
            guard !Task.isCancelled, index == page else { return }
            _ = await loadHighResolution(at: neighbor, allowCameraRequest: allowCameraRequest)
        }
    }

    @MainActor
    private func trimPreviewState() {
        let keep = retainedPhotoPreviewIDs(entries: previewEntries, currentIndex: index)
        highResolutionImages = highResolutionImages.filter { keep.contains($0.key) }
        localHighResolutionSources = localHighResolutionSources.filter { keep.contains($0.key) }
        displayedImages = displayedImages.filter { keep.contains($0.key) }
        fhdUnavailable.formIntersection(keep)
        localDecodeFailures = localDecodeFailures.filter { keep.contains($0.key) }
        exifByFile = exifByFile.filter { keep.contains($0.key) }
        exifFinished.formIntersection(keep)
    }

    private func isVideo(_ file: CameraFile) -> Bool {
        [".mov", ".mp4"].contains(file.fileExtension.lowercased())
    }

    private func transferredOriginal(_ file: CameraFile) -> Bool {
        transferredFileIDs.contains(file.id) || localOriginalURLs[file.id] != nil ||
            queueModel.task(for: file.id)?.status == .completed
    }

    private func collapseCurrentBurst() {
        guard !closing, !burstTransitionBusy, !queueFlightActive,
              abs(queueDragOffset) < 0.5 else { return }
        guard let collectionIndex = photoPreviewCollectionIndex(previewEntries, memberIndex: index),
              case let .burst(group) = previewEntries[collectionIndex] else { return }
        burstTransitionBusy = true
        animatedBurstID = group.id
        ZTransferHaptics.shared.tick()
        burstTransitionTask?.cancel()
        burstTransitionTask = Task { @MainActor in
            burstStackMotion = 1
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.12)) {
                burstPagerScale = 0.985
                burstPagerAlpha = 0
                burstPagerSlide = 0.22
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let transaction = Transaction(animation: nil)
            withTransaction(transaction) {
                index = collectionIndex
                previewEntries = collapsePhotoPreviewBurst(previewEntries, burstID: group.id)
                expandedBurstIDs.remove(group.id)
                selectedFile = group.files.first
                burstPagerSlide = -0.22
            }
            onBurstChanged(group.id, false)
            await Task.yield()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                burstStackMotion = 0
                burstPagerScale = 1
            }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)) {
                burstPagerAlpha = 1
            }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.165)) {
                burstPagerSlide = 0
            }
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            resetBurstTransition()
        }
    }

    private func expandBurst(_ group: BurstPhotoGroup) {
        guard !closing, !burstTransitionBusy, !group.files.isEmpty else { return }
        guard let collectionIndex = previewEntries.firstIndex(where: { entry in
            if case .burst(let value) = entry { return value.id == group.id }
            return false
        }), index == collectionIndex else { return }
        burstTransitionBusy = true
        animatedBurstID = group.id
        ZTransferHaptics.shared.tick()
        burstTransitionTask?.cancel()
        burstTransitionTask = Task { @MainActor in
            burstStackMotion = 0
            if !expandedBurstIDs.contains(group.id) {
                let transaction = Transaction(animation: nil)
                withTransaction(transaction) {
                    previewEntries = expandPhotoPreviewBurst(previewEntries, at: collectionIndex)
                    expandedBurstIDs.insert(group.id)
                }
                onBurstChanged(group.id, true)
                await Task.yield()
            }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.165)) {
                burstStackMotion = 1
            }
            try? await Task.sleep(nanoseconds: 24_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.205)) {
                index = collectionIndex + 1
            }
            selectedFile = group.files.first
            try? await Task.sleep(nanoseconds: 205_000_000)
            guard !Task.isCancelled else { return }
            resetBurstTransition()
        }
    }

    private func resetBurstTransition() {
        let transaction = Transaction(animation: nil)
        withTransaction(transaction) {
            burstStackMotion = 0
            burstPagerScale = 1
            burstPagerAlpha = 1
            burstPagerSlide = 0
            animatedBurstID = nil
            burstTransitionBusy = false
            burstTransitionTask = nil
        }
    }

    private func startQueueFlight(for file: CameraFile, burstFiles: [CameraFile]? = nil) {
        guard !closing, !burstTransitionBusy, !queueFlightActive else { return }
        guard burstFiles.map(onEnqueueBurst) ?? onEnqueue(file) else { return }
        ZTransferHaptics.shared.tick()
        let flightCount = burstFiles?.count ?? 1
        onQueueFlightStarted(flightCount)
        queueFlightCount = flightCount
        queueFlightActive = true
        queueFlightProgress = 0
        queueFlightImage = nil
        queueFlightImages = []
        withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.155)) {
            queueDragOffset = -132
        }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78).delay(0.155)) {
            queueDragOffset = 0
        }
        withAnimation(.timingCurve(0.5, 0, 0.8, 0.35, duration: 0.56).delay(0.035)) {
            queueFlightProgress = 1
        }
        queueFlightTask?.cancel()
        queueFlightTask = Task { @MainActor in
            let flightFiles = burstFiles?.prefix(3).map { $0 } ?? [file]
            var cachedImages: [UIImage] = []
            var cachedLayers: [UIImage?] = []
            for candidate in flightFiles {
                if let data = try? await session.cachedThumbnail(file: candidate),
                   let image = UIImage(data: data) {
                    cachedImages.append(image)
                    cachedLayers.append(image)
                } else {
                    cachedLayers.append(nil)
                }
            }
            queueFlightImages = cachedLayers
            if let image = cachedImages.first {
                queueFlightImage = image
            }
            try? await Task.sleep(nanoseconds: 560_000_000)
            guard !Task.isCancelled else { return }
            queueDragOffset = 0
            queueFlightActive = false
            onQueueFlightFinished(flightCount)
            queueFlightCount = 0
            queueFlightTask = nil
        }
    }
}

private func luminanceHistogram(_ image: UIImage) -> [CGFloat] {
    guard let cg = image.cgImage else { return [] }
    let width = min(cg.width, 320), height = min(cg.height, 240)
    guard width > 0, height > 0 else { return [] }
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
    context.interpolationQuality = .low
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    var bins = [Int](repeating: 0, count: 24)
    for pixel in pixels { bins[min(23, Int(pixel) * 24 / 256)] += 1 }
    let maxValue = max(1, bins.max() ?? 1)
    return bins.map { CGFloat($0) / CGFloat(maxValue) }
}

private struct PhotoPreviewQueueFlightView: View {
    let progress: CGFloat
    let image: UIImage?
    let images: [UIImage?]
    let from: CGPoint
    let target: CGPoint
    let size: CGSize
    let stackCount: Int

    var body: some View {
        let p = min(max(progress, 0), 1)
        let control = CGPoint(
            x: from.x + (target.x - from.x) * 0.42,
            y: min(from.y, target.y) - max(56, abs(target.x - from.x) * 0.18)
        )
        let position = previewQuadraticBezier(start: from, control: control, end: target, t: p)
        let width = max(10, size.width * (1 - p * 0.56))
        let height = max(10, size.height * (1 - p * 0.56))
        ZStack {
            ForEach(Array(0..<min(max(stackCount, 1), 3)), id: \.self) { layer in
                Group {
                    if let image = (images.indices.contains(layer) ? images[layer] : nil) ?? image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.26))
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: max(8, width * 0.04)))
                .overlay(RoundedRectangle(cornerRadius: max(8, width * 0.04)).stroke(.white.opacity(0.32), lineWidth: 1))
                .offset(x: CGFloat(layer - 1) * min(12, width * 0.04), y: CGFloat(layer) * 5)
                .rotationEffect(.degrees(Double(p) * 8 + Double(layer - 1) * 3))
            }
        }
        .position(position)
        .opacity(1 - p * 0.2)
    }
}

private func previewQuadraticBezier(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
    let oneMinus = 1 - t
    return CGPoint(
        x: oneMinus * oneMinus * start.x + 2 * oneMinus * t * control.x + t * t * end.x,
        y: oneMinus * oneMinus * start.y + 2 * oneMinus * t * control.y + t * t * end.y
    )
}

private struct PreviewCircleButton: View {
    let symbol: String
    let accessibilityKey: String
    var active = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "plus" ? size * 0.5 : 20, weight: .semibold))
                .foregroundStyle(ZTransferColors.accentBlue)
                .frame(width: size, height: size)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(active ? 0.9 : 0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalized.resource(accessibilityKey))
    }
}

/// Android's collapsed burst page: a compact stack of up to three cached
/// thumbnails with a count badge and an explicit expand affordance.  It never
/// starts a camera request solely to draw the stack; uncached members remain
/// placeholders until their normal preview page is selected.
private struct BurstCollectionPreview: View {
    let session: CameraSession
    let group: BurstPhotoGroup
    let stackMotion: CGFloat
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * 0.72, proxy.size.height * 0.46)
            ZStack {
                ForEach(Array(group.files.prefix(3).reversed().enumerated()), id: \.element.id) { index, file in
                    let last = min(2, group.files.count - 1)
                    let spread: CGFloat = index == last ? 0 : (index.isMultiple(of: 2) ? -1 : 1)
                    CachedBurstThumbnail(session: session, file: file)
                        .frame(width: side * 0.86, height: side * 0.86)
                        .rotationEffect(.degrees(index == 0 ? -6 : index == 1 ? 5 : 0))
                        .offset(x: index == 0 ? -12 : index == 1 ? 12 : 0,
                                y: index == 2 ? 2 : 5)
                        .offset(x: spread * 6 * stackMotion)
                        .scaleEffect(1 + 0.012 * stackMotion)
                }
                HStack(spacing: 4) {
                    BurstGlyph().frame(width: 23, height: 13)
                    Text("\(group.files.count)")
                }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.teal.opacity(0.9), in: Capsule())
                    .frame(width: side, height: side, alignment: .topLeading)
                    .padding(8)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(perform: onTap)
        }
    }
}

private struct CachedBurstThumbnail: View {
    let session: CameraSession
    let file: CameraFile
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.14))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.32), lineWidth: 1))
        .task {
            guard image == nil else { return }
            if let data = try? await session.cachedThumbnail(file: file), let decoded = UIImage(data: data) {
                image = decoded
            }
        }
    }
}

private struct PreviewImage: View {
    let session: CameraSession
    let file: CameraFile
    let highResolutionImage: UIImage?
    let rotationDegrees: Double
    let zoomEnabled: Bool
    let allowRemoteThumbnailFallback: Bool
    let onDisplayImage: (UIImage?) -> Void
    let onTap: () -> Void
    let onZoomedChange: (Bool) -> Void
    let isCurrent: Bool
    @State private var thumbnail: UIImage?
    @State private var remoteThumbnailUnavailable = false
    @State private var highResolutionAlpha: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureStartScale: CGFloat = 1
    @State private var gestureStartOffset: CGSize = .zero

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable().scaledToFit()
                    .opacity(zoomEnabled
                             ? (highResolutionImage == nil ? 1 : 1 - highResolutionAlpha)
                             : 0.56)
            }
            if let highResolutionImage {
                Image(uiImage: highResolutionImage)
                    .resizable().scaledToFit()
                    .opacity(thumbnail == nil ? 1 : highResolutionAlpha)
            }
            if thumbnail == nil && highResolutionImage == nil {
                if remoteThumbnailUnavailable {
                    Text(AppLocalized.resource("no_preview"))
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().tint(.white)
                }
            }
            if !zoomEnabled {
                VStack(spacing: 6) {
                    Text(AppLocalized.resource("video_no_preview"))
                        .font(.system(size: 14, weight: .semibold))
                    let metadata = videoPreviewMetadata(file: file)
                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.22), lineWidth: 1))
            }
        }
        .scaleEffect(scale).offset(offset).rotationEffect(.degrees(rotationDegrees))
        .gesture(MagnificationGesture().onChanged { value in
            guard zoomEnabled else { return }
            scale = min(max(gestureStartScale * value, 1), 4)
            onZoomedChange(scale > 1.01)
        }.onEnded { _ in
            guard zoomEnabled else { return }
            gestureStartScale = scale
            if scale <= 1.01 { offset = .zero; gestureStartOffset = .zero }
        })
        .simultaneousGesture(DragGesture().onChanged { value in
            if zoomEnabled, scale > 1.01 {
                offset = CGSize(width: gestureStartOffset.width + value.translation.width,
                                height: gestureStartOffset.height + value.translation.height)
            }
        }.onEnded { _ in
            gestureStartOffset = scale > 1.01 ? offset : .zero
            if scale <= 1.01 { offset = .zero }
        })
        .onTapGesture(count: 2) {
            guard zoomEnabled else { return }
            withAnimation(.linear(duration: 0.24)) {
                scale = scale > 1.01 ? 1 : 2.5
                if scale <= 1.01 { offset = .zero }
            }
            gestureStartScale = scale
            gestureStartOffset = offset
            onZoomedChange(scale > 1.01)
        }
        .onTapGesture { if scale <= 1.01 { onTap() } }
        .onChange(of: isCurrent) { current in
            if !current { scale = 1; offset = .zero; gestureStartScale = 1; gestureStartOffset = .zero }
        }
        .onChange(of: rotationDegrees) { _ in
            scale = 1; offset = .zero; gestureStartScale = 1; gestureStartOffset = .zero
            onZoomedChange(false)
        }
        .onChange(of: highResolutionImage) { image in
            guard let image else {
                highResolutionAlpha = 0
                return
            }
            onDisplayImage(image)
            if thumbnail == nil {
                highResolutionAlpha = 1
            } else {
                withAnimation(.easeInOut(duration: 0.18)) { highResolutionAlpha = 1 }
            }
        }
        .task(id: file.id) {
            thumbnail = nil
            highResolutionAlpha = 0
            remoteThumbnailUnavailable = false
            // Android publishes a cached thumbnail immediately, then waits
            // for the overlay transition to settle before opening the FHD
            // channel. This avoids competing with the opening animation.
            if let data = try? await session.cachedThumbnail(file: file),
               let thumb = UIImage(data: data) {
                thumbnail = thumb
                onDisplayImage(thumb)
            }
            if highResolutionImage != nil {
                highResolutionAlpha = thumbnail == nil ? 1 : 0
                if thumbnail != nil {
                    withAnimation(.easeInOut(duration: 0.18)) { highResolutionAlpha = 1 }
                }
            }
        }
        .task(id: allowRemoteThumbnailFallback) {
            guard allowRemoteThumbnailFallback, thumbnail == nil, highResolutionImage == nil else { return }
            guard let data = try? await session.thumbnail(file: file),
                  let thumb = UIImage(data: data) else {
                if !Task.isCancelled { remoteThumbnailUnavailable = true }
                return
            }
            guard !Task.isCancelled else { return }
            thumbnail = thumb
            onDisplayImage(thumb)
        }
    }
}

private struct PreviewExifBar: View {
    let exif: PhotoExif
    var body: some View {
        let values = [exif.aperture, exif.shutterSpeed, exif.iso, exif.exposureCompensation, exif.focalLength].compactMap { $0 }
        if values.isEmpty { EmptyView() } else {
            Text(values.joined(separator: "\u{2009}·\u{2009}"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }
}
