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

/// Android ThumbnailPreviewPriorityTest: remote fallback belongs exclusively
/// to the current page, after both FHD failure and EXIF completion.
func allowPreviewRemoteThumbnailFallback(
    isCurrent: Bool, fhdUnavailable: Bool, exifFinished: Bool
) -> Bool {
    isCurrent && fhdUnavailable && exifFinished
}

private struct PreviewPageOffsets: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

func nearestPreviewPage(offsets: [Int: CGFloat]) -> (index: Int, offset: CGFloat)? {
    guard let nearest = offsets.filter({ $0.value.isFinite }).min(by: {
        abs($0.value) == abs($1.value) ? $0.key < $1.key : abs($0.value) < abs($1.value)
    }), abs(nearest.value) <= 0.501 else { return nil }
    return (nearest.key, nearest.value)
}

func previewPageInformationAlpha(_ offsetFraction: CGFloat) -> CGFloat {
    min(max(1 - abs(offsetFraction) * 2, 0), 1)
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

func videoPreviewMetadata(file: CameraFile) -> String {
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

struct PhotoPreviewView: View {
    @ObservedObject var queueModel: TransferQueueViewModel
    let session: CameraSession
    let isSessionConnected: Bool
    let files: [CameraFile]
    let burstGroups: [BurstPhotoGroup]
    let burstIDByFile: [UInt32: String]
    let transferredFileIDs: Set<UInt32>
    let queueTarget: CGRect?
    let directory: URL?
    let storageMode: TransferStorageMode
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
    let onCropConfirmed: (CameraFile, JpegCropSelection) -> Void
    private let initialIndex: Int
    @State private var index: Int
    @State private var pagerSelection: Int
    @State private var pageOffsetFraction: CGFloat = 0
    @State private var exifLoadedAlpha: CGFloat = 0
    @State private var previewEntries: [PhotoPreviewEntry]
    @State private var rotationDegrees: Double = 0
    @State private var cropPresented = false
    @State private var cropSelection = JpegCropSelection(bounds: .init(left: 0, top: 0, right: 1, bottom: 1), orientation: 1)
    @State private var cropSources: [UInt32: JpegCropSource] = [:]
    @AppStorage("preview_rotation_quarter_turns") private var rotationQuarterTurns = 0
    @State private var previewSafeInsets = EdgeInsets()
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
    /// Exported-file presence is used only for the transferred badge.
    /// Android 1.91 ordinary previews always obtain their image from camera FHD.
    @State private var localOriginalURLs: [UInt32: URL]

    init(session: CameraSession, queueModel: TransferQueueViewModel, files: [CameraFile],
         isSessionConnected: Bool = true,
         burstIDByFile: [UInt32: String] = [:], transferredFileIDs: Set<UInt32> = [],
         selectedFile: Binding<CameraFile?>,
         directory: URL? = nil, storageMode: TransferStorageMode = .unified,
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
         onDismiss: @escaping (CameraFile?) -> Void = { _ in },
         onCropConfirmed: @escaping (CameraFile, JpegCropSelection) -> Void = { _, _ in }) {
        self.queueModel = queueModel
        self.isSessionConnected = isSessionConnected
        self.session = session; self.files = files; self.directory = directory
        self.burstGroups = PhotoCatalogGrouping.bursts(in: files)
        self.burstIDByFile = burstIDByFile
        self.transferredFileIDs = transferredFileIDs
        self.queueTarget = queueTarget
        self.initialAnchor = initialAnchor
        self.storageMode = storageMode; _selectedFile = selectedFile
        self.onEnqueue = onEnqueue; self.onEnqueueBurst = onEnqueueBurst
        self.onQueueFlightStarted = onQueueFlightStarted
        self.onQueueFlightFinished = onQueueFlightFinished
        self.onQueueFlightCancelled = onQueueFlightCancelled
        self.onBurstChanged = onBurstChanged
        self.prepareDismissTarget = prepareDismissTarget
        self.onDismiss = onDismiss
        self.onCropConfirmed = onCropConfirmed
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
        _pagerSelection = State(initialValue: initialIndex)
        _collapseAnchor = State(initialValue: initialAnchor)
        var sources: [UInt32: URL] = [:]
        if let directory {
            for file in files {
                let destination = transferDestinationDirectory(
                    root: directory,
                    folderName: transferStorageFolderName(file: file, mode: storageMode)
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
            TabView(selection: $pagerSelection) {
                ForEach(Array(previewEntries.enumerated()), id: \.element.id) { itemIndex, entry in
                    Group {
                        switch entry {
                        case .photo(let file, _):
                            PreviewImage(session: session, file: file,
                                         highResolutionImage: highResolutionImages[file.id],
                                         rotationDegrees: rotationDegrees,
                                         infoBottom: previewSafeInsets.top + ((currentPhoto.map { burstIDByFile[$0.id] != nil || $0.isProtected } ?? false) ? 112 : 70),
                                         interactive: !closing && !queueFlightActive && !burstTransitionBusy && queueDragDirection != .upward,
                                         zoomEnabled: !file.fileExtension.lowercased().hasSuffix(".mov") &&
                                            !file.fileExtension.lowercased().hasSuffix(".mp4"),
                                         loadEnabled: deferredLoadsEnabled,
                                         allowRemoteThumbnailFallback: isSessionConnected &&
                                            allowPreviewRemoteThumbnailFallback(
                                                isCurrent: itemIndex == index,
                                                fhdUnavailable: fhdUnavailable.contains(file.id),
                                                exifFinished: exifFinished.contains(file.id)
                                            ),
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
                                .padding(.bottom, previewSafeInsets.bottom + 88)
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
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PreviewPageOffsets.self,
                                value: [itemIndex: proxy.size.width > 0
                                    ? proxy.frame(in: .named("photoPreviewPager")).minX / proxy.size.width : 0])
                        }
                    }
                    .tag(itemIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .coordinateSpace(name: "photoPreviewPager")
            .onPreferenceChange(PreviewPageOffsets.self) { offsets in
                guard !closing, !burstTransitionBusy,
                      let page = nearestPreviewPage(offsets: offsets),
                      previewEntries.indices.contains(page.index) else { return }
                // Observation changes current content at halfway; it never sends
                // a programmatic selection back into the moving TabView.
                index = page.index
                pageOffsetFraction = page.offset
            }
            .onChange(of: pagerSelection) { index = $0 }

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
            if let file = currentPhoto {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        PreviewInfoText(text: file.fileName)
                            .layoutPriority(1)
                            .opacity(previewInformationAlpha)
                            .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
                        if let task = queueModel.task(for: file.id), task.status != .completed {
                            PhotoPreviewLiveTransferBadge(
                                task: task,
                                progressModel: queueModel.progressModel
                            )
                        } else if transferredOriginal(file) { TransferredPhotoBadge() }
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(height: 36)
                    .padding(.trailing, 172)
                    Group {
                        if let exif { PreviewExifBar(exif: exif) }
                        else { Color.clear }
                    }
                    .frame(height: 26, alignment: .topLeading)
                    .opacity(previewInformationAlpha * exifLoadedAlpha)
                    .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
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
                        .padding(.top, 8)
                        .opacity(previewInformationAlpha)
                        .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
                    }
                }
                .padding(.top, 6).padding(.horizontal, 12)
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
                    HStack(spacing: 12) {
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
                            PreviewCircleButton(icon: .crop, accessibilityKey: "cd_crop_photo") {
                                cropSelection = .init(bounds: .init(left: 0, top: 0, right: 1, bottom: 1), orientation: displayOrientation(for: rotationDegrees))
                                cropPresented = true
                                Task {
                                    if let header = try? await session.readPrefix(file: file, length: 64 * 1024),
                                       let source = parseJpegCropHeader(header) {
                                        await MainActor.run { cropSources[file.id] = source }
                                    }
                                }
                            }
                        }
                        PreviewCircleButton(icon: .add, accessibilityKey: "cd_transfer") {
                            startQueueFlight(for: file)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.trailing, 20).padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.easeInOut(duration: 0.18), value: currentPhoto == nil)
            .allowsHitTesting(currentPhoto != nil)
            if !histogramBars.isEmpty {
                PreviewHistogramOverlay(values: histogramBars)
                    .padding(.leading, 20).padding(.bottom, 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .opacity(histogramOverlayVisible ? previewInformationAlpha : 0)
                    .animation(.easeInOut(duration: 0.18), value: histogramOverlayVisible)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { previewSafeInsets = proxy.safeAreaInsets }
                    .onChange(of: proxy.safeAreaInsets) { previewSafeInsets = $0 }
            }
        }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--photo-preview-ui-test") {
                Text("page=\(index);zoom=\(currentZoomed ? 1 : 0);pinch=\(magnificationActive ? 1 : 0)")
                    .font(.system(size: 8)).allowsHitTesting(false)
                    .accessibilityIdentifier("preview-state")
            }
        }
        #endif
        .allowsHitTesting(!burstTransitionBusy && !closing)
        .sheet(isPresented: $cropPresented) {
            if let file = currentPhoto, let image = highResolutionImages[file.id] ?? displayedImages[file.id] {
                NavigationStack {
                    PhotoCropEditor(image: image, orientation: cropSelection.orientation, selection: $cropSelection)
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { cropPresented = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("完成") {
                                let parsed = cropSources[file.id]
                                let source = JpegCropSource(width: parsed?.width ?? Int(image.size.width), height: parsed?.height ?? Int(image.size.height), mcuWidth: parsed?.mcuWidth ?? 8, mcuHeight: parsed?.mcuHeight ?? 8, orientation: cropSelection.orientation)
                                if let recipe = try? cropSelection.resolve(source) {
                                    LosslessCropTaskStore().upsert(.init(fileID: file.id, recipe: recipe))
                                }
                                onCropConfirmed(file, cropSelection); cropPresented = false
                            } }
                        }
                }
            }
        }
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
        .onChange(of: exif != nil) { loaded in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) {
                exifLoadedAlpha = loaded ? 1 : 0
            }
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

    private var previewInformationAlpha: Double {
        Double(presentationProgress * burstPagerAlpha * previewPageInformationAlpha(pageOffsetFraction))
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
                      presentationProgress >= 0.99, abs(pageOffsetFraction) < 0.01, !queueFlightActive,
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
        return "\(entryID)|\(deferredLoadsEnabled)|\(isSessionConnected)"
    }

    @MainActor
    private func loadCurrentThenNeighbors() async {
        trimPreviewState()
        guard let file = currentPhoto else {
            exif = nil
            return
        }
        exif = exifByFile[file.id]
        exifLoading = isSessionConnected && !exifFinished.contains(file.id)
        guard isSessionConnected else { return }

        // A previous neighbor request may still own this handle while unwinding.
        while highResolutionLoading.contains(file.id) {
            do { try await Task.sleep(nanoseconds: 16_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        let needsPreview = !isVideo(file) && highResolutionImages[file.id] == nil
        let needsExif = !exifFinished.contains(file.id)
        if needsPreview {
            fhdUnavailable.remove(file.id)
            highResolutionLoading.insert(file.id)
        } else if isVideo(file) {
            fhdUnavailable.insert(file.id)
        }
        let (_, metadata) = await session.previewAndExif(
            file: file, loadPreview: needsPreview, loadExif: needsExif,
            onPreviewLoaded: { data in
                highResolutionLoading.remove(file.id)
                finishRemoteImageLoad(file: file, data: data)
            }
        )
        highResolutionLoading.remove(file.id)
        guard !Task.isCancelled else { return }
        finishRemoteExifLoad(file: file, metadata: metadata, loadedExif: needsExif)
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
        if highResolutionImages[id] != nil { return false }
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
        guard allowCameraRequest, isSessionConnected, !Task.isCancelled else { return false }
        fhdUnavailable.remove(id)
        highResolutionLoading.insert(id)
        defer { highResolutionLoading.remove(id) }
        guard let data = try? await session.preview(handle: id),
              !Task.isCancelled,
              let image = UIImage(data: data) else {
            if !Task.isCancelled { fhdUnavailable.insert(id) }
            return false
        }
        highResolutionImages[id] = image
        displayedImages[id] = image
        fhdUnavailable.remove(id)
        return true
    }

    @MainActor
    private func finishRemoteImageLoad(file: CameraFile, data: Data?) {
        if let data, let image = UIImage(data: data) {
            highResolutionImages[file.id] = image
            displayedImages[file.id] = image
            fhdUnavailable.remove(file.id)
            ZTransferHaptics.shared.tick()
        } else if highResolutionImages[file.id] == nil {
            fhdUnavailable.insert(file.id)
        }
    }

    @MainActor
    private func finishRemoteExifLoad(file: CameraFile, metadata: PhotoExif?, loadedExif: Bool) {
        if loadedExif {
            if let metadata { exifByFile[file.id] = metadata }
            exifFinished.insert(file.id)
        }
        if currentPhoto?.id == file.id {
            exif = exifByFile[file.id]
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
        displayedImages = displayedImages.filter { keep.contains($0.key) }
        fhdUnavailable.formIntersection(keep)
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
                pagerSelection = collectionIndex
                pageOffsetFraction = 0
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
                pagerSelection = collectionIndex + 1
                pageOffsetFraction = 0
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

private struct PhotoPreviewLiveTransferBadge: View {
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
    case collapse, expand, histogram, rotateLeft, crop, add
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
        case .rotateLeft, .crop, .add: return size * 0.5
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

            case .crop:
                let scale = min(size.width, size.height) / 24
                var crop = Path()
                crop.addRect(CGRect(x: 5 * scale, y: 5 * scale, width: 14 * scale, height: 14 * scale))
                context.stroke(crop, with: tint, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .square))
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
    let infoBottom: CGFloat
    let interactive: Bool
    let zoomEnabled: Bool
    let loadEnabled: Bool
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
    @State private var magnifying = false

    var body: some View {
        let cachedThumbnail = thumbnail ?? session.memoryThumbnailImage(file: file)
        GeometryReader { proxy in
            ZStack {
                if let cachedThumbnail {
                    Image(uiImage: cachedThumbnail)
                        .resizable().scaledToFit()
                        // Keep the placeholder opaque underneath the FHD reveal.
                        .opacity(1)
                }
                if let highResolutionImage {
                    Image(uiImage: highResolutionImage)
                        .resizable().scaledToFit()
                        .opacity(cachedThumbnail == nil ? 1 : highResolutionAlpha)
                }
                if zoomEnabled && cachedThumbnail == nil && highResolutionImage == nil {
                    if remoteThumbnailUnavailable {
                        Text(AppLocalized.resource("no_preview"))
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                if !zoomEnabled {
                    Color.black.opacity(0.5)
                    VStack(spacing: 6) {
                        Text(AppLocalized.resource("video_no_preview"))
                            .font(.system(size: 14, weight: .medium))
                        let metadata = videoPreviewMetadata(file: file)
                        if !metadata.isEmpty {
                            Text(metadata)
                                .font(.system(size: 12, weight: .medium))
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
                rotationDegrees: zoomEnabled ? rotationDegrees : 0,
                targetRotationDegrees: zoomEnabled ? rotationDegrees : 0,
                imageSize: zoomEnabled ? (highResolutionImage ?? cachedThumbnail)?.size : nil,
                viewportSize: proxy.size,
                infoBottom: infoBottom,
                zoomScale: scale
            ))
            .offset(offset)
            .simultaneousGesture(panGesture(
                viewportSize: proxy.size,
                imageSize: (highResolutionImage ?? cachedThumbnail)?.size
            ), including: zoomEnabled && scale > 1.01 ? .all : .none)
            .simultaneousGesture(tapGesture(
                viewportSize: proxy.size,
                viewportFrame: proxy.frame(in: .global),
                imageSize: (highResolutionImage ?? cachedThumbnail)?.size
            ))
            .overlay {
                PreviewPinchObserver(enabled: interactive && zoomEnabled && isCurrent && (highResolutionImage ?? cachedThumbnail) != nil,
                    onActive: { active in
                        magnifying = active
                        if !active { gestureStartOffset = offset; gestureStartScale = scale }
                    },
                    onChange: { factor, centroid, pan in
                        applyPinch(factor: factor, centroid: centroid, pan: pan,
                                   viewportSize: proxy.size,
                                   imageSize: (highResolutionImage ?? cachedThumbnail)?.size)
                    })
            }
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
        .task(id: highResolutionImage) {
            guard let image = highResolutionImage else {
                highResolutionAlpha = 0
                return
            }
            onDisplayImage(image)
            guard thumbnail != nil || session.memoryThumbnailImage(file: file) != nil else {
                highResolutionAlpha = 1
                return
            }
            highResolutionAlpha = 0
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                highResolutionAlpha = CGFloat(ZTransferAndroidMotion.fastOutSlowIn(
                    Float(min(max(elapsed / 0.3, 0), 1))
                ))
                if elapsed >= 0.3 { break }
                do { try await Task.sleep(nanoseconds: 16_000_000) }
                catch { return }
            }
        }
        .task(id: file.id) {
            thumbnail = nil
            remoteThumbnailUnavailable = false
            // Android publishes a cached thumbnail immediately, then waits
            // for the overlay transition to settle before opening the FHD
            // channel. This avoids competing with the opening animation.
            if let thumb = session.memoryThumbnailImage(file: file) {
                thumbnail = thumb
                onDisplayImage(thumb)
            }
        }
        .task(id: "\(file.id)|\(loadEnabled)|\(allowRemoteThumbnailFallback)") {
            guard loadEnabled, thumbnail == nil, !remoteThumbnailUnavailable else { return }
            guard let thumb = try? await session.thumbnailImage(file: file, allowRemote: allowRemoteThumbnailFallback) else {
                if !Task.isCancelled && allowRemoteThumbnailFallback { remoteThumbnailUnavailable = true }
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
    private func applyPinch(factor: CGFloat, centroid: CGPoint, pan: CGSize,
                            viewportSize: CGSize, imageSize: CGSize?) {
        guard interactive, zoomEnabled, isCurrent else { return }
        zoomAnimationTask?.cancel()
        zoomAnimationTask = nil
        zoomAnimationActive = false
        let maximum = photoPreviewMaximumZoom(imageSize: imageSize,
                                               viewportSize: viewportSize,
                                               rotationDegrees: rotationDegrees, infoBottom: infoBottom)
        let nextScale = min(max(scale * factor, 1), maximum)
        let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                              rotationDegrees: rotationDegrees, infoBottom: infoBottom)
        let proposed = previewPinchOffset(offset: offset,
            centroidFromCenter: CGPoint(x: centroid.x - placement.center.x,
                                        y: centroid.y - placement.center.y),
            factor: nextScale / scale, pan: pan)
        offset = photoPreviewClampedOffset(proposed, scale: nextScale, imageSize: imageSize,
                                           viewportSize: viewportSize, rotationDegrees: rotationDegrees, infoBottom: infoBottom)
        scale = nextScale
        onZoomedChange(scale > 1.01)
    }

    private func panGesture(viewportSize: CGSize, imageSize: CGSize?) -> some Gesture {
        DragGesture(minimumDistance: photoPreviewZoomPanMinimumDistance)
            .onChanged { value in
                guard interactive, zoomEnabled, !magnifying, scale > 1.01 else { return }
                offset = photoPreviewClampedOffset(
                    CGSize(
                        width: gestureStartOffset.width + value.translation.width,
                        height: gestureStartOffset.height + value.translation.height
                    ),
                    scale: scale,
                    imageSize: imageSize,
                    viewportSize: viewportSize,
                    rotationDegrees: rotationDegrees, infoBottom: infoBottom
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
                    if interactive, scale <= 1.01, !zoomAnimationActive { onTap() }
                }
            }
    }

    private func handleDoubleTap(at location: CGPoint, viewportSize: CGSize, imageSize: CGSize?) {
        guard interactive, zoomEnabled else { return }
        zoomAnimationTask?.cancel()
        let restoring = scale > 1.01
        let targetScale: CGFloat = restoring ? 1 : photoPreviewDoubleTapZoom
        let targetOffset = restoring ? .zero : photoPreviewDoubleTapOffset(
            location: location,
            scale: targetScale,
            imageSize: imageSize,
            viewportSize: viewportSize,
            rotationDegrees: rotationDegrees, infoBottom: infoBottom
        )
        zoomAnimationActive = true
        if !restoring { onZoomedChange(true) }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: photoPreviewDoubleTapDuration)) {
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
    return fit
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

struct PhotoPreviewPlacement {
    let scale: CGFloat
    let size: CGSize
    let center: CGPoint
}

/// Final Android ZoomablePreviewViewport: width inset, information clearance,
/// portrait lift and rotation all contribute to the actual resting geometry.
func photoPreviewPlacement(imageSize: CGSize?, viewportSize: CGSize,
                           rotationDegrees: Double, infoBottom: CGFloat? = nil,
                           targetRotationDegrees: Double? = nil) -> PhotoPreviewPlacement {
    let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    guard let imageSize, imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else {
        return PhotoPreviewPlacement(scale: 1, size: viewportSize, center: center)
    }
    let aspect = imageSize.width / imageSize.height
    let baseWidth = min(viewportSize.width, viewportSize.height * aspect)
    let baseHeight = baseWidth / aspect
    let radians = rotationDegrees * .pi / 180
    let width = baseWidth * abs(cos(radians)) + baseHeight * abs(sin(radians))
    let height = baseWidth * abs(sin(radians)) + baseHeight * abs(cos(radians))
    let orientedAspect = abs(Int(((targetRotationDegrees ?? rotationDegrees) / 90).rounded())) % 2 == 1 ? 1 / aspect : aspect
    let inset: CGFloat = infoBottom == nil ? 0 : (orientedAspect < 1 ? 40 : 24)
    let fit = min(max(1, viewportSize.width - inset) / width, viewportSize.height / height)
    guard let infoBottom else {
        return PhotoPreviewPlacement(scale: fit, size: CGSize(width: width * fit, height: height * fit), center: center)
    }
    let layout = previewPhotoLayout(viewportHeight: viewportSize.height, imageHeight: height * fit,
                                    infoBottom: infoBottom, cropTop: 0, cropExtraBottom: 84, progress: 0)
    let lift: CGFloat = orientedAspect < 1 ? min(12, max(0, layout.centerY - height * fit * layout.scale / 2 - infoBottom)) : 0
    let scale = fit * layout.scale
    return PhotoPreviewPlacement(scale: scale, size: CGSize(width: width * scale, height: height * scale),
                                 center: CGPoint(x: center.x, y: layout.centerY - lift))
}

/// Android PreviewGestureGeometry.kt. Coordinates are relative to the resting
/// image center; applying the incremental factor preserves the touched pixel.
func previewPinchOffset(offset: CGSize, centroidFromCenter: CGPoint,
                        factor: CGFloat, pan: CGSize) -> CGSize {
    CGSize(width: offset.width * factor + centroidFromCenter.x * (1 - factor) + pan.width,
           height: offset.height * factor + centroidFromCenter.y * (1 - factor) + pan.height)
}

func clampPreviewPan(scale: CGFloat, offset: CGSize, image: CGSize,
                     viewport: CGSize, center: CGPoint) -> CGSize {
    guard scale > 1 else { return .zero }
    func axis(_ value: CGFloat, extent: CGFloat, container: CGFloat, origin: CGFloat) -> CGFloat {
        guard extent > container else { return 0 }
        let minimum = min(0, container - origin - extent / 2)
        let maximum = max(0, extent / 2 - origin)
        return min(max(value, minimum), maximum)
    }
    return CGSize(width: axis(offset.width, extent: image.width * scale,
                              container: viewport.width, origin: center.x),
                  height: axis(offset.height, extent: image.height * scale,
                               container: viewport.height, origin: center.y))
}

struct PreviewPhotoLayout: Equatable {
    let scale: CGFloat
    let centerY: CGFloat
}

func previewPhotoLayout(viewportHeight: CGFloat, imageHeight: CGFloat, infoBottom: CGFloat,
                        cropTop: CGFloat, cropExtraBottom: CGFloat, progress: CGFloat,
                        cropTopAlignment: CGFloat = 1) -> PreviewPhotoLayout {
    let height = max(viewportHeight, 1)
    let normalTop = min(max(infoBottom, 0), height - 1)
    let bottom = max(height - cropExtraBottom, 1)
    let top = min(max(cropTop, 0), bottom - 1)
    let normalScale = min(1, (height - normalTop) / max(imageHeight, 1))
    let cropScale = min(1, (bottom - top) / max(imageHeight, 1))
    let p = min(max(progress, 0), 1)
    let normalCenter = (normalTop + height) / 2
    let halfHeight = imageHeight * cropScale / 2
    let upperCenter = top + halfHeight
    let cropCenter = min(max(normalCenter + (upperCenter - normalCenter) *
                             min(max(cropTopAlignment, 0), 1), upperCenter),
                         max(upperCenter, bottom - halfHeight))
    return PreviewPhotoLayout(scale: normalScale + (cropScale - normalScale) * p,
                              centerY: normalCenter + (cropCenter - normalCenter) * p)
}

func photoPreviewClampedOffset(
    _ proposed: CGSize,
    scale: CGFloat,
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double,
    infoBottom: CGFloat? = nil
) -> CGSize {
    let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                          rotationDegrees: rotationDegrees, infoBottom: infoBottom)
    return clampPreviewPan(scale: scale, offset: proposed, image: placement.size,
                           viewport: viewportSize, center: placement.center)
}

func photoPreviewDoubleTapOffset(
    location: CGPoint,
    scale: CGFloat,
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double,
    infoBottom: CGFloat? = nil
) -> CGSize {
    let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                          rotationDegrees: rotationDegrees, infoBottom: infoBottom)
    return photoPreviewClampedOffset(
        CGSize(
            width: (location.x - placement.center.x) * (1 - scale),
            height: (location.y - placement.center.y) * (1 - scale)
        ),
        scale: scale,
        imageSize: imageSize,
        viewportSize: viewportSize,
        rotationDegrees: rotationDegrees, infoBottom: infoBottom
    )
}

func photoPreviewMaximumZoom(
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double,
    infoBottom: CGFloat? = nil
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
    let fit = max(0.01, photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                             rotationDegrees: rotationDegrees,
                                             infoBottom: infoBottom).scale)
    let oneToOne = max(imageSize.width / baseWidth, imageSize.height / baseHeight) / fit
    return max(4, oneToOne)
}

@preconcurrency
private struct PreviewRotationTransform: AnimatableModifier {
    var rotationDegrees: Double
    let targetRotationDegrees: Double
    let imageSize: CGSize?
    let viewportSize: CGSize
    var infoBottom: CGFloat? = nil
    var zoomScale: CGFloat = 1

    nonisolated var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(rotationDegrees, zoomScale) }
        set { rotationDegrees = newValue.first; zoomScale = newValue.second }
    }

    func body(content: Content) -> some View {
        let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                              rotationDegrees: rotationDegrees, infoBottom: infoBottom,
                                              targetRotationDegrees: targetRotationDegrees)
        content
            .scaleEffect(placement.scale * zoomScale)
            .rotationEffect(.degrees(rotationDegrees))
            .offset(y: placement.center.y - viewportSize.height / 2)
    }
}

private struct PreviewInfoText: View {
    let text: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach([14, 13, 12], id: \.self) { size in
                Text(text).font(.system(size: CGFloat(size), weight: .medium))
                    .tracking(0.1).lineLimit(1).fixedSize(horizontal: true, vertical: true)
            }
            Text(text).font(.system(size: 11, weight: .medium))
                .tracking(0.1).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(.white.opacity(0.88))
    }
}

private struct PreviewExifBar: View {
    let exif: PhotoExif
    var body: some View {
        let values = [exif.aperture, exif.shutterSpeed, exif.iso, exif.exposureCompensation, exif.focalLength].compactMap { $0 }
        if !values.isEmpty {
            PreviewInfoText(text: values.joined(separator: "\u{2009}·\u{2009}"))
        }
    }
}
