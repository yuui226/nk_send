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

enum PhotoPreviewQueueDragDirection: Equatable {
    case undecided
    case upward
    case rejected
}

/// Match Android's direction lock: horizontal/downward movement is released
/// to the pager immediately, while a diagonal drag stays undecided until its
/// upward component is at least 1.15x the horizontal component.
func photoPreviewQueueDragDirection(
    translation: CGSize,
    touchSlop: CGFloat = 8
) -> PhotoPreviewQueueDragDirection {
    guard hypot(translation.width, translation.height) >= touchSlop else {
        return .undecided
    }
    let upwardDistance = -translation.height
    if translation.height >= 0 || abs(translation.width) > upwardDistance {
        return .rejected
    }
    return upwardDistance >= abs(translation.width) * 1.15 ? .upward : .undecided
}

func photoPreviewQueueVisualOffset(
    upwardDistance: CGFloat,
    triggerDistance: CGFloat = 96
) -> CGFloat {
    guard triggerDistance > 0 else { return 0 }
    let distance = max(0, upwardDistance)
    let resisted = min(distance, triggerDistance) +
        max(0, distance - triggerDistance) * 0.22
    return -min(resisted, triggerDistance * 1.24)
}

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
    let onQueueFlightCancelled: (Int) -> Void
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
    @State private var histogramFileID: UInt32?
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
    @State private var queueDragDirection: PhotoPreviewQueueDragDirection = .undecided
    @State private var currentZoomed = false
    @State private var magnificationActive = false
    @State private var queueFlightTask: Task<Void, Never>?
    @State private var queueFlightActive = false
    @State private var queueFlightStartedAt: Date?
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
         onQueueFlightCancelled: @escaping (Int) -> Void = { _ in },
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
        self.onQueueFlightCancelled = onQueueFlightCancelled
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
                                             if let image {
                                                 showHistogram(for: file, image: image)
                                             } else {
                                                 histogramFileID = nil
                                             }
                                         }, onTap: startClose,
                                         onZoomedChange: { zoomed in if index == itemIndex { currentZoomed = zoomed } },
                                         onMagnificationChange: { active in
                                             guard index == itemIndex else { return }
                                             magnificationActive = active
                                             if active {
                                                 queueDragDirection = .rejected
                                                 settleQueueDrag()
                                             }
                                         },
                                         isCurrent: index == itemIndex)
                        case .burst(let group):
                            BurstCollectionPreview(
                                session: session,
                                group: group,
                                stackMotion: animatedBurstID == group.id ? burstStackMotion : 0,
                                onTransfer: {
                                    if let first = group.files.first {
                                        startQueueFlight(for: first, burstFiles: group.files)
                                    }
                                },
                                onExpand: { expandBurst(group) },
                                onTap: startClose
                            )
                        }
                    }
                        .tag(itemIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Android's HorizontalPager owns the complete edge-to-edge stage;
            // only its controls apply system-bar padding. Center the image in
            // that same full-screen viewport instead of the reduced safe area.
            .ignoresSafeArea()
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
            // Once an upward queue drag wins direction arbitration, cancel
            // the page scroll recognizer for the rest of this touch. A normal
            // horizontal drag keeps the pager enabled.
            .scrollDisabled(
                currentZoomed || magnificationActive || queueDragDirection == .upward ||
                    queueFlightActive || burstTransitionBusy
            )
            .allowsHitTesting(
                !queueFlightActive && !closing && !burstTransitionBusy &&
                    queueDragDirection != .upward
            )
            if queueFlightActive, previewEntries.indices.contains(index) {
                GeometryReader { proxy in
                    let screen = UIScreen.main.bounds
                    let resolvedTarget = queueTarget.flatMap { frame in
                        frame.isEmpty || frame.isInfinite || frame.isNull ? nil : frame
                    } ?? CGRect(x: screen.maxX - 13, y: 48, width: 1, height: 36)
                    PhotoPreviewQueueFlightView(
                        startedAt: queueFlightStartedAt,
                        image: queueFlightImage,
                        images: queueFlightImages,
                        from: CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.46),
                        target: CGPoint(
                            // Match the list/Android landing point: the stable
                            // right edge of the carrier, inset into the capsule.
                            x: resolvedTarget.maxX - 28 - proxy.frame(in: .global).minX,
                            y: resolvedTarget.midY - proxy.frame(in: .global).minY
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
                        Text(file.fileName)
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
            if let file = currentPhoto, highResolutionLoading.contains(file.id) {
                Rectangle()
                    .fill(ZTransferColors.accentBlue.opacity(0.9))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            ZStack {
                if let file = currentPhoto {
                    VStack(spacing: 12) {
                        if photoPreviewCollectionIndex(previewEntries, memberIndex: index) != nil {
                            PreviewCircleButton(icon: .collapse, accessibilityKey: "cd_collapse") {
                                collapseCurrentBurst()
                            }
                        }
                        if !isVideo(file) {
                            PreviewCircleButton(icon: .histogram, accessibilityKey: "cd_preview_histogram", active: histogramVisible) {
                                histogramVisible.toggle()
                            }
                            PreviewCircleButton(icon: .rotateLeft, accessibilityKey: "cd_rotate_photo") {
                                let nextDegrees = rotationDegrees - 90
                                // Match Android's animateFloatAsState(tween(220)):
                                // keep accumulating the target angle so repeated
                                // taps always continue counter-clockwise rather
                                // than snapping across the 0/360-degree boundary.
                                withAnimation(photoPreviewRotationAnimation) {
                                    rotationDegrees = nextDegrees
                                }
                                rotationQuarterTurns = ((Int(-nextDegrees / 90) % 4) + 4) % 4
                            }
                        }
                        PreviewCircleButton(icon: .add, accessibilityKey: "cd_transfer") {
                            startQueueFlight(for: file)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.trailing, 20).padding(.bottom, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.easeInOut(duration: 0.18), value: currentPhoto == nil)
            .allowsHitTesting(currentPhoto != nil)
            if !histogramBars.isEmpty {
                PreviewHistogramOverlay(values: histogramBars)
                    .padding(.leading, 20).padding(.bottom, 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .opacity(histogramOverlayVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: histogramOverlayVisible)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(!burstTransitionBusy && !closing)
        // Keep the arbiter on the stable overlay rather than the TabView. The
        // TabView can therefore be disabled after an upward lock without
        // cancelling the gesture that owns the queue drag.
        .simultaneousGesture(previewQueueSwipeGesture)
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
            if queueFlightCount > 0 { onQueueFlightCancelled(queueFlightCount) }
            queueFlightCount = 0
            queueFlightStartedAt = nil
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
                magnificationActive = false
                trimPreviewState()
                refreshHistogramForCurrentPhoto()
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
            if visible { refreshHistogramForCurrentPhoto() }
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

    private var histogramOverlayVisible: Bool {
        photoPreviewHistogramOverlayVisible(
            enabled: histogramVisible,
            currentPhotoID: currentPhoto?.id,
            histogramFileID: histogramFileID,
            binCount: histogramBars.count
        )
    }

    private func refreshHistogramForCurrentPhoto() {
        guard histogramVisible, let file = currentPhoto else { return }
        guard let image = displayedImages[file.id] else {
            histogramFileID = nil
            return
        }
        showHistogram(for: file, image: image)
    }

    private func showHistogram(for file: CameraFile, image: UIImage) {
        let bars = previewLuminanceHistogram(image)
        withAnimation(.easeInOut(duration: 0.18)) {
            histogramBars = bars
            histogramFileID = file.id
        }
    }

    private var previewQueueSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard currentPhoto != nil, !currentZoomed, !magnificationActive,
                      presentationProgress >= 0.99, !queueFlightActive,
                      !closing, !burstTransitionBusy else {
                    queueDragDirection = .rejected
                    return
                }
                if queueDragDirection == .undecided {
                    let resolved = photoPreviewQueueDragDirection(translation: value.translation)
                    if resolved != .undecided { queueDragDirection = resolved }
                }
                guard queueDragDirection == .upward else { return }
                queueDragOffset = photoPreviewQueueVisualOffset(
                    upwardDistance: -value.translation.height
                )
            }
            .onEnded { value in
                let resolved = queueDragDirection == .undecided
                    ? photoPreviewQueueDragDirection(translation: value.translation)
                    : queueDragDirection
                queueDragDirection = .undecided
                guard resolved == .upward,
                      !currentZoomed, !magnificationActive, !queueFlightActive,
                      previewEntries.indices.contains(index) else {
                    settleQueueDrag()
                    return
                }
                if -value.translation.height >= 96, let file = currentPhoto {
                    startQueueFlight(for: file)
                } else {
                    settleQueueDrag()
                }
            }
    }

    private func settleQueueDrag() {
        guard abs(queueDragOffset) >= 0.5 else {
            queueDragOffset = 0
            return
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            queueDragOffset = 0
        }
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
            return
        }
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
        let flightCount = burstFiles?.count ?? 1
        onQueueFlightStarted(flightCount)
        guard burstFiles.map(onEnqueueBurst) ?? onEnqueue(file) else {
            onQueueFlightCancelled(flightCount)
            return
        }
        ZTransferHaptics.shared.tick()
        queueFlightCount = flightCount
        queueFlightActive = true
        queueFlightStartedAt = Date().addingTimeInterval(0.032)
        queueFlightImage = nil
        queueFlightImages = []
        let riseDuration: UInt64 = queueDragOffset < -1 ? 105_000_000 : 155_000_000
        withAnimation(.timingCurve(
            0.4, 0.0, 0.2, 1.0,
            duration: Double(riseDuration) / 1_000_000_000
        )) {
            queueDragOffset = -132
        }
        queueFlightTask?.cancel()
        queueFlightTask = Task { @MainActor in
            let flightFiles = burstFiles?.prefix(3).map { $0 } ?? [file]
            var cachedLayers: [UIImage?] = []
            for candidate in flightFiles {
                cachedLayers.append(
                    displayedImages[candidate.id] ?? session.memoryThumbnailImage(file: candidate)
                )
            }
            queueFlightImages = cachedLayers
            queueFlightImage = displayedImages[file.id]
                ?? cachedLayers.compactMap { $0 }.first
            // The immutable start time already includes Android's 32 ms
            // preroll. Wait for the complete rise before issuing the return.
            try? await Task.sleep(nanoseconds: riseDuration)
            guard !Task.isCancelled, queueFlightActive else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                queueDragOffset = 0
            }
            try? await Task.sleep(nanoseconds: 592_000_000 - riseDuration)
            guard !Task.isCancelled else { return }
            queueDragOffset = 0
            queueFlightActive = false
            onQueueFlightFinished(flightCount)
            queueFlightCount = 0
            queueFlightTask = nil
        }
    }
}

func photoPreviewHistogramOverlayVisible(
    enabled: Bool,
    currentPhotoID: UInt32?,
    histogramFileID: UInt32?,
    binCount: Int
) -> Bool {
    enabled && currentPhotoID != nil && currentPhotoID == histogramFileID && binCount > 0
}

func previewLuminanceHistogram(_ image: UIImage) -> [CGFloat] {
    guard let cg = image.cgImage else { return [] }
    // Android samples roughly 24k pixels, uses the Rec.709 integer weights
    // (54 + 183 + 19 = 256), and retains all 256 bins. Downsample once during
    // the existing background task instead of analysing the full-resolution
    // original or reducing the curve to a visibly different 24-column chart.
    let sourcePixels = Double(max(1, cg.width * cg.height))
    let sampleScale = min(1, sqrt(24_000 / sourcePixels))
    let width = max(1, Int((Double(cg.width) * sampleScale).rounded()))
    let height = max(1, Int((Double(cg.height) * sampleScale).rounded()))
    guard width > 0, height > 0 else { return [] }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
        CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else { return [] }
    context.interpolationQuality = .low
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    var bins = [Int](repeating: 0, count: 256)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let luminance = (54 * Int(pixels[offset]) +
                         183 * Int(pixels[offset + 1]) +
                         19 * Int(pixels[offset + 2])) >> 8
        bins[luminance] += 1
    }
    let maxValue = max(1, bins.max() ?? 1)
    return bins.map { CGFloat($0) / CGFloat(maxValue) }
}

/// Android's shared 118x62 histogram: 256-bin filled luminance curve, bright
/// outline and a faint baseline. This is intentionally not a bar chart.
private struct PreviewHistogramOverlay: View {
    let values: [CGFloat]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let left: CGFloat = 7
            let top: CGFloat = 6
            let width = max(0, size.width - left * 2)
            let height = max(0, size.height - top * 2)
            let bottom = top + height
            var curve = Path()
            curve.move(to: CGPoint(x: left, y: bottom))
            for (index, value) in values.enumerated() {
                curve.addLine(to: CGPoint(
                    x: left + width * CGFloat(index) / CGFloat(values.count - 1),
                    y: top + height * (1 - min(1, max(0, value)))
                ))
            }
            curve.addLine(to: CGPoint(x: left + width, y: bottom))
            curve.closeSubpath()
            context.fill(curve, with: .color(.white.opacity(0.28)))
            context.stroke(
                curve,
                with: .color(.white.opacity(0.90)),
                style: StrokeStyle(lineWidth: 1.05, lineCap: .round)
            )
            var baseline = Path()
            baseline.move(to: CGPoint(x: left, y: bottom))
            baseline.addLine(to: CGPoint(x: left + width, y: bottom))
            context.stroke(baseline, with: .color(.white.opacity(0.22)), lineWidth: 0.75)
        }
        .frame(width: 118, height: 62)
        .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PhotoPreviewQueueFlightView: View {
    let startedAt: Date?
    let image: UIImage?
    let images: [UIImage?]
    let from: CGPoint
    let target: CGPoint
    let size: CGSize
    let stackCount: Int

    var body: some View {
        // The view exists for less than a second, so keep its timeline live.
        // The immutable future start date supplies the transparent preroll
        // without asking a paused timeline to resume after insertion.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let linear = startedAt.map {
                min(max(timeline.date.timeIntervalSince($0) / 0.56, 0), 1)
            } ?? 0
            let layerCount = stackCount > 1 ? min(stackCount, 3) : 1
            ZStack {
                ForEach(Array(0..<layerCount), id: \.self) { layer in
                    Group {
                        if let image = (images.indices.contains(layer) ? images[layer] : nil) ?? image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.26))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.32), lineWidth: 1))
                    .offset(
                        x: layerCount > 1 ? CGFloat(layer - 1) * 12 : 0,
                        y: layerCount > 1 ? CGFloat(1 - layer) * 5 : 0
                    )
                    .rotationEffect(.degrees(layerCount > 1 ? Double(layer - 1) * 9 : 0))
                }
            }
            // TimelineView advances the path itself. This avoids the SwiftUI
            // insertion + implicit-animation coalescing that could leave only
            // the fully transparent endpoint and make the flight disappear.
            .modifier(PhotoPreviewQueueFlightArc(
                progress: queueFlightEasedProgress(CGFloat(linear)),
                start: from,
                end: target,
                baseSize: size
            ))
        }
    }
}

@preconcurrency
private struct PhotoPreviewQueueFlightArc: AnimatableModifier {
    var progress: CGFloat
    let start: CGPoint
    let end: CGPoint
    let baseSize: CGSize

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
        let point = photoPreviewQuadraticBezier(start: start, control: control, end: end, t: t)
        let appear = min(t / 0.12, 1)
        let endScale = 18 / max(max(baseSize.width, baseSize.height), 1)
        let scale = 0.82 + (endScale - 0.82) * t
        let arc = sin(.pi * t)
        return content
            .scaleEffect(scale)
            .rotationEffect(.degrees(Double(2.2 * arc)))
            .opacity(appear * (t > 0.94 ? (1 - t) / 0.06 : 1) * 0.86)
            .position(point)
    }
}

private func photoPreviewQuadraticBezier(
    start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat
) -> CGPoint {
    let remaining = 1 - t
    return CGPoint(
        x: remaining * remaining * start.x + 2 * remaining * t * control.x + t * t * end.x,
        y: remaining * remaining * start.y + 2 * remaining * t * control.y + t * t * end.y
    )
}

private enum PreviewControlIcon: Equatable {
    case collapse, expand, histogram, rotateLeft, add
}

private struct PreviewCircleButton: View {
    let icon: PreviewControlIcon
    let accessibilityKey: String
    var active = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PreviewControlMark(icon: icon)
                .frame(width: markSize, height: markSize)
                .foregroundStyle(ZTransferColors.accentBlue)
                .frame(width: size, height: size)
        }
        // Android BurstCollectionNavigationButton,
        // PreviewHistogramButton and TransferQueueButton all use GlassButton.
        .buttonStyle(ZTransferGlassButtonStyle(
            cornerRadius: size / 2,
            active: active,
            activeColor: ZTransferColors.accentBlue
        ))
        .accessibilityLabel(AppLocalized.resource(accessibilityKey))
    }

    private var markSize: CGFloat {
        switch icon {
        case .collapse, .expand: return 25
        case .histogram: return 20
        case .rotateLeft, .add: return size * 0.5
        }
    }
}

/// Code-drawn copies of the Android Material/control marks. SF Symbols use a
/// different taper, optical width and bar count, which is obvious when the
/// four controls are stacked together.
private struct PreviewControlMark: View {
    let icon: PreviewControlIcon

    var body: some View {
        Canvas { context, size in
            let tint = GraphicsContext.Shading.color(ZTransferColors.accentBlue)
            switch icon {
            case .histogram:
                let lineWidth: CGFloat = 1.5
                let barWidth = (size.width - 7) / 5
                let gap: CGFloat = 1.5
                let baseY = size.height - 2
                let heights: [CGFloat] = [0.38, 0.62, 0.85, 0.55, 0.28]
                for index in 0..<5 {
                    let x = 2.5 + CGFloat(index) * (barWidth + gap)
                    var bar = Path()
                    bar.move(to: CGPoint(x: x, y: baseY))
                    bar.addLine(to: CGPoint(x: x, y: baseY - baseY * heights[index]))
                    context.stroke(
                        bar,
                        with: tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                }

            case .add:
                let scale = min(size.width, size.height) / 24
                var plus = Path()
                plus.addRect(CGRect(x: 5 * scale, y: 11 * scale,
                                    width: 14 * scale, height: 2 * scale))
                plus.addRect(CGRect(x: 11 * scale, y: 5 * scale,
                                    width: 2 * scale, height: 14 * scale))
                context.fill(plus, with: tint)

            case .collapse, .expand:
                let scale = min(size.width, size.height) / 24
                var chevron = Path()
                if icon == .collapse {
                    chevron.move(to: CGPoint(x: 15.41 * scale, y: 7.41 * scale))
                    chevron.addLine(to: CGPoint(x: 14 * scale, y: 6 * scale))
                    chevron.addLine(to: CGPoint(x: 8 * scale, y: 12 * scale))
                    chevron.addLine(to: CGPoint(x: 14 * scale, y: 18 * scale))
                    chevron.addLine(to: CGPoint(x: 15.41 * scale, y: 16.59 * scale))
                    chevron.addLine(to: CGPoint(x: 10.83 * scale, y: 12 * scale))
                } else {
                    chevron.move(to: CGPoint(x: 8.59 * scale, y: 16.59 * scale))
                    chevron.addLine(to: CGPoint(x: 10 * scale, y: 18 * scale))
                    chevron.addLine(to: CGPoint(x: 16 * scale, y: 12 * scale))
                    chevron.addLine(to: CGPoint(x: 10 * scale, y: 6 * scale))
                    chevron.addLine(to: CGPoint(x: 8.59 * scale, y: 7.41 * scale))
                    chevron.addLine(to: CGPoint(x: 13.17 * scale, y: 12 * scale))
                }
                chevron.closeSubpath()
                context.fill(chevron, with: tint)

            case .rotateLeft:
                let scale = min(size.width, size.height) / 24
                let rotation = materialRotateLeftPath(scale: scale)
                context.fill(rotation, with: tint)
            }
        }
    }
}

/// `Icons.Default.RotateLeft` from the Android Material icon set, expressed in
/// its native 24x24 viewport and scaled only at draw time.
private func materialRotateLeftPath(scale: CGFloat) -> Path {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
    var path = Path()
    path.move(to: point(7.11, 8.53))
    path.addLine(to: point(5.70, 7.11))
    path.addCurve(to: point(4.07, 11), control1: point(4.80, 8.27), control2: point(4.24, 9.61))
    path.addLine(to: point(6.09, 11))
    path.addCurve(to: point(7.11, 8.53), control1: point(6.23, 10.13), control2: point(6.58, 9.28))
    path.closeSubpath()

    path.move(to: point(6.09, 13))
    path.addLine(to: point(4.07, 13))
    path.addCurve(to: point(5.69, 16.89), control1: point(4.24, 14.39), control2: point(4.79, 15.73))
    path.addLine(to: point(7.10, 15.47))
    path.addCurve(to: point(6.09, 13), control1: point(6.58, 14.72), control2: point(6.23, 13.88))
    path.closeSubpath()

    path.move(to: point(7.10, 18.32))
    path.addCurve(to: point(11, 19.93), control1: point(8.26, 19.22), control2: point(9.61, 19.76))
    path.addLine(to: point(11, 17.90))
    path.addCurve(to: point(8.54, 16.87), control1: point(10.13, 17.75), control2: point(9.29, 17.41))
    path.addLine(to: point(7.10, 18.32))
    path.closeSubpath()

    path.move(to: point(13, 4.07))
    path.addLine(to: point(13, 1))
    path.addLine(to: point(8.45, 5.55))
    path.addLine(to: point(13, 10))
    path.addLine(to: point(13, 6.09))
    path.addCurve(to: point(18, 12), control1: point(15.84, 6.57), control2: point(18, 9.03))
    path.addCurve(to: point(13, 17.91), control1: point(18, 14.97), control2: point(15.84, 17.43))
    path.addLine(to: point(13, 19.93))
    path.addCurve(to: point(20, 12), control1: point(16.95, 19.44), control2: point(20, 16.08))
    path.addCurve(to: point(13, 4.07), control1: point(20, 7.92), control2: point(16.95, 4.56))
    path.closeSubpath()
    return path
}

/// Android's collapsed burst page: a compact stack of up to three cached
/// thumbnails with a count badge and an explicit expand affordance.  It never
/// starts a camera request solely to draw the stack; uncached members remain
/// placeholders until their normal preview page is selected.
private struct BurstCollectionPreview: View {
    let session: CameraSession
    let group: BurstPhotoGroup
    let stackMotion: CGFloat
    let onTransfer: () -> Void
    let onExpand: () -> Void
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * 0.72, proxy.size.height * 0.46)
            ZStack {
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
                .onTapGesture(perform: onTap)

                HStack(spacing: 22) {
                    PreviewCircleButton(
                        icon: .add,
                        accessibilityKey: "cd_transfer_group",
                        size: 48,
                        action: onTransfer
                    )
                    PreviewCircleButton(
                        icon: .expand,
                        accessibilityKey: "cd_expand",
                        action: onExpand
                    )
                }
                .padding(.bottom, 112 + proxy.safeAreaInsets.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CachedBurstThumbnail: View {
    let session: CameraSession
    let file: CameraFile
    @State private var image: UIImage?

    init(session: CameraSession, file: CameraFile) {
        self.session = session
        self.file = file
        _image = State(initialValue: session.memoryThumbnailImage(file: file))
    }

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
            image = try? await session.thumbnailImage(file: file, allowRemote: false)
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
    let onMagnificationChange: (Bool) -> Void
    let isCurrent: Bool
    @State private var thumbnail: UIImage?
    @State private var remoteThumbnailUnavailable = false
    @State private var highResolutionAlpha: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureStartScale: CGFloat = 1
    @State private var gestureStartOffset: CGSize = .zero
    @State private var zoomAnimationTask: Task<Void, Never>?
    @State private var zoomAnimationActive = false
    @GestureState private var magnifying = false

    var body: some View {
        GeometryReader { proxy in
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
            .frame(width: proxy.size.width, height: proxy.size.height)
            .modifier(PreviewRotationTransform(
                rotationDegrees: rotationDegrees,
                imageSize: (highResolutionImage ?? thumbnail)?.size,
                viewportSize: proxy.size
            ))
            .scaleEffect(scale)
            .offset(offset)
            .simultaneousGesture(magnificationGesture(
                viewportSize: proxy.size,
                imageSize: (highResolutionImage ?? thumbnail)?.size
            ))
            .simultaneousGesture(panGesture(
                viewportSize: proxy.size,
                imageSize: (highResolutionImage ?? thumbnail)?.size
            ), including: zoomEnabled && scale > 1.01 ? .all : .none)
            .simultaneousGesture(tapGesture(
                viewportSize: proxy.size,
                viewportFrame: proxy.frame(in: .global),
                imageSize: (highResolutionImage ?? thumbnail)?.size
            ))
        }
        .onChange(of: magnifying) { active in
            onMagnificationChange(active)
        }
        .onChange(of: isCurrent) { current in
            if !current {
                zoomAnimationTask?.cancel()
                zoomAnimationTask = nil
                zoomAnimationActive = false
                scale = 1
                offset = .zero
                gestureStartScale = 1
                gestureStartOffset = .zero
                onMagnificationChange(false)
            }
        }
        .onChange(of: rotationDegrees) { _ in
            // Zoom reset is not part of the rotation tween. Keeping it out of
            // the inherited transaction prevents a scale jump from looking
            // like a one-frame image replacement.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                zoomAnimationTask?.cancel()
                zoomAnimationTask = nil
                zoomAnimationActive = false
                scale = 1
                offset = .zero
                gestureStartScale = 1
                gestureStartOffset = .zero
            }
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
            if let thumb = session.memoryThumbnailImage(file: file) {
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
            guard let thumb = try? await session.thumbnailImage(file: file) else {
                if !Task.isCancelled { remoteThumbnailUnavailable = true }
                return
            }
            guard !Task.isCancelled else { return }
            thumbnail = thumb
            onDisplayImage(thumb)
        }
        .onDisappear {
            zoomAnimationTask?.cancel()
            zoomAnimationTask = nil
            onMagnificationChange(false)
        }
    }

    // These recognizers coexist with PageTabViewStyle's UIScrollView pan.
    // At 1x the image pan stays dormant so a one-finger horizontal drag belongs
    // only to the pager; a two-finger gesture explicitly rejects queue swiping.
    private func magnificationGesture(viewportSize: CGSize, imageSize: CGSize?) -> some Gesture {
        MagnificationGesture()
            .updating($magnifying) { _, active, _ in active = true }
            .onChanged { value in
                guard zoomEnabled else { return }
                zoomAnimationTask?.cancel()
                zoomAnimationTask = nil
                zoomAnimationActive = false
                let maximum = photoPreviewMaximumZoom(
                    imageSize: imageSize,
                    viewportSize: viewportSize,
                    rotationDegrees: rotationDegrees
                )
                scale = min(max(gestureStartScale * value, 1), maximum)
                offset = photoPreviewClampedOffset(
                    offset,
                    scale: scale,
                    imageSize: imageSize,
                    viewportSize: viewportSize,
                    rotationDegrees: rotationDegrees
                )
                onZoomedChange(scale > 1.01)
            }
            .onEnded { _ in
                guard zoomEnabled else { return }
                gestureStartScale = scale
                if scale <= 1.01 {
                    offset = .zero
                    gestureStartOffset = .zero
                } else {
                    gestureStartOffset = offset
                }
            }
    }

    private func panGesture(viewportSize: CGSize, imageSize: CGSize?) -> some Gesture {
        DragGesture(minimumDistance: photoPreviewZoomPanMinimumDistance)
            .onChanged { value in
                guard zoomEnabled, scale > 1.01 else { return }
                offset = photoPreviewClampedOffset(
                    CGSize(
                        width: gestureStartOffset.width + value.translation.width,
                        height: gestureStartOffset.height + value.translation.height
                    ),
                    scale: scale,
                    imageSize: imageSize,
                    viewportSize: viewportSize,
                    rotationDegrees: rotationDegrees
                )
            }
            .onEnded { _ in
                gestureStartOffset = scale > 1.01 ? offset : .zero
                if scale <= 1.01 { offset = .zero }
            }
    }

    private func tapGesture(
        viewportSize: CGSize,
        viewportFrame: CGRect,
        imageSize: CGSize?
    ) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: CoordinateSpace.global)
            .exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: CoordinateSpace.global))
            .onEnded { value in
                switch value {
                case .first(let doubleTap):
                    handleDoubleTap(
                        at: CGPoint(
                            x: doubleTap.location.x - viewportFrame.minX,
                            y: doubleTap.location.y - viewportFrame.minY
                        ),
                        viewportSize: viewportSize,
                        imageSize: imageSize
                    )
                case .second:
                    if scale <= 1.01, !zoomAnimationActive { onTap() }
                }
            }
    }

    private func handleDoubleTap(at location: CGPoint, viewportSize: CGSize, imageSize: CGSize?) {
        guard zoomEnabled else { return }
        zoomAnimationTask?.cancel()
        let restoring = scale > 1.01
        let targetScale: CGFloat = restoring ? 1 : photoPreviewDoubleTapZoom
        let targetOffset = restoring ? .zero : photoPreviewDoubleTapOffset(
            location: location,
            scale: targetScale,
            imageSize: imageSize,
            viewportSize: viewportSize,
            rotationDegrees: rotationDegrees
        )
        zoomAnimationActive = true
        if !restoring { onZoomedChange(true) }
        withAnimation(.linear(duration: photoPreviewDoubleTapDuration)) {
            scale = targetScale
            offset = targetOffset
        }
        gestureStartScale = targetScale
        gestureStartOffset = targetOffset
        zoomAnimationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(photoPreviewDoubleTapDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            zoomAnimationActive = false
            zoomAnimationTask = nil
            if restoring { onZoomedChange(false) }
        }
    }
}

let photoPreviewRotationDuration = 0.22
let photoPreviewZoomPanMinimumDistance: CGFloat = 8
let photoPreviewDoubleTapDuration = 0.24
let photoPreviewDoubleTapZoom: CGFloat = 2.5
private let photoPreviewRotationAnimation =
    Animation.timingCurve(0.4, 0, 0.2, 1, duration: photoPreviewRotationDuration)

/// Continuously recomputed rotation fit used by Android's graphicsLayer.
/// Calculating it from the interpolated angle keeps portrait and landscape
/// photos inside the viewport for every frame instead of resizing only after
/// the quarter turn has finished.
func photoPreviewRotationFitScale(
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double
) -> CGFloat {
    guard let imageSize,
          imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
    let rawAspect = imageSize.width / imageSize.height
    let viewportAspect = viewportSize.width / viewportSize.height
    let baseWidth = rawAspect > viewportAspect
        ? viewportSize.width
        : viewportSize.height * rawAspect
    let baseHeight = rawAspect > viewportAspect
        ? viewportSize.width / rawAspect
        : viewportSize.height
    let radians = rotationDegrees * .pi / 180
    let absoluteCosine = abs(cos(radians))
    let absoluteSine = abs(sin(radians))
    let rotatedWidth = baseWidth * absoluteCosine + baseHeight * absoluteSine
    let rotatedHeight = baseWidth * absoluteSine + baseHeight * absoluteCosine
    guard rotatedWidth > 0, rotatedHeight > 0 else { return 1 }
    let fit = min(viewportSize.width / rotatedWidth, viewportSize.height / rotatedHeight)
    let breathingRoom = rawAspect > 1 ? 1 - 0.08 * absoluteSine : 1
    return fit * breathingRoom
}

/// Axis-aligned size of the fitted image at the current quarter-turn target.
/// Android uses this size when constraining pan so no empty space can be pulled
/// into the viewport after zooming.
func photoPreviewDisplaySize(
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double
) -> CGSize {
    guard let imageSize,
          imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else { return viewportSize }
    let rawAspect = imageSize.width / imageSize.height
    let quarterTurns = Int((rotationDegrees / 90).rounded())
    let orientedAspect = abs(quarterTurns) % 2 == 1 ? 1 / rawAspect : rawAspect
    let viewportAspect = viewportSize.width / viewportSize.height
    if orientedAspect > viewportAspect {
        return CGSize(width: viewportSize.width, height: viewportSize.width / orientedAspect)
    }
    return CGSize(width: viewportSize.height * orientedAspect, height: viewportSize.height)
}

func photoPreviewClampedOffset(
    _ proposed: CGSize,
    scale: CGFloat,
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double
) -> CGSize {
    let displaySize = photoPreviewDisplaySize(
        imageSize: imageSize,
        viewportSize: viewportSize,
        rotationDegrees: rotationDegrees
    )
    let maximumX = max(0, (displaySize.width * scale - viewportSize.width) / 2)
    let maximumY = max(0, (displaySize.height * scale - viewportSize.height) / 2)
    return CGSize(
        width: min(max(proposed.width, -maximumX), maximumX),
        height: min(max(proposed.height, -maximumY), maximumY)
    )
}

func photoPreviewDoubleTapOffset(
    location: CGPoint,
    scale: CGFloat,
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double
) -> CGSize {
    photoPreviewClampedOffset(
        CGSize(
            width: (location.x - viewportSize.width / 2) * (1 - scale),
            height: (location.y - viewportSize.height / 2) * (1 - scale)
        ),
        scale: scale,
        imageSize: imageSize,
        viewportSize: viewportSize,
        rotationDegrees: rotationDegrees
    )
}

func photoPreviewMaximumZoom(
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double
) -> CGFloat {
    guard let imageSize,
          imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else { return 4 }
    let rawAspect = imageSize.width / imageSize.height
    let viewportAspect = viewportSize.width / viewportSize.height
    let baseWidth = rawAspect > viewportAspect
        ? viewportSize.width
        : viewportSize.height * rawAspect
    let baseHeight = rawAspect > viewportAspect
        ? viewportSize.width / rawAspect
        : viewportSize.height
    let fit = max(0.01, photoPreviewRotationFitScale(
        imageSize: imageSize,
        viewportSize: viewportSize,
        rotationDegrees: rotationDegrees
    ))
    let oneToOne = max(imageSize.width / baseWidth, imageSize.height / baseHeight) / fit
    return max(4, oneToOne)
}

@preconcurrency
private struct PreviewRotationTransform: AnimatableModifier {
    var rotationDegrees: Double
    let imageSize: CGSize?
    let viewportSize: CGSize

    nonisolated var animatableData: Double {
        get { rotationDegrees }
        set { rotationDegrees = newValue }
    }

    func body(content: Content) -> some View {
        let fit = photoPreviewRotationFitScale(
            imageSize: imageSize,
            viewportSize: viewportSize,
            rotationDegrees: rotationDegrees
        )
        content
            .scaleEffect(fit)
            .rotationEffect(.degrees(rotationDegrees))
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
