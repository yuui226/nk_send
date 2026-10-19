import SwiftUI
import UIKit
import ImageIO

/// Match Android's previewItems/page/connection/deferred-load effect keys.
/// Transfer activity is intentionally excluded so it cannot cancel an active read.
struct PhotoPreviewLoadIdentity: Equatable {
    let entryIDs: [String]
    let index: Int
    let deferredLoadsEnabled: Bool
    let connected: Bool
    var retry: Int = 0
}

/// Eviction follows the live page window independently of asynchronous loading.
/// Observing the retained IDs also covers burst changes with an unchanged index.
struct PhotoPreviewRetentionObserver: ViewModifier {
    let retainedIDs: Set<UInt32>
    let trim: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: trim)
            .onChange(of: retainedIDs) { _ in trim() }
    }
}

/// Share mode semantics with monitoring, but keep the photo preference scope.
struct PhotoPreviewHistogramPreferences: DynamicProperty {
    @AppStorage private var legacyEnabled: Bool
    @AppStorage private var savedMode: String

    init(store: UserDefaults = .standard) {
        _legacyEnabled = AppStorage(wrappedValue: false, "preview_histogram_enabled", store: store)
        _savedMode = AppStorage(wrappedValue: "", "preview_histogram_mode", store: store)
    }

    var mode: RemoteHistogramMode {
        get { .restore(saved: savedMode, previouslyEnabled: legacyEnabled) }
        nonmutating set { savedMode = newValue.rawValue }
    }
}

/// A source replacement (including a higher-resolution image of the same file)
/// invalidates the prior calculation. Cancellation alone is insufficient when
/// a synchronous image operation has already started.
@MainActor
final class PhotoPreviewHistogramModel: ObservableObject {
    struct Snapshot: Equatable {
        var result = PhotoPreviewHistogram()
        var fileID: UInt32?
    }
    @Published private(set) var snapshot = Snapshot()
    var result: PhotoPreviewHistogram { snapshot.result }
    var bars: [CGFloat] { snapshot.result.luma }
    var fileID: UInt32? { snapshot.fileID }
    private var sourceImage: UIImage?
    private var sourceFileID: UInt32?
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private let calculate: @Sendable (UIImage) async -> PhotoPreviewHistogram

    init(calculate: @escaping @Sendable (UIImage) async -> PhotoPreviewHistogram = { image in
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return PhotoPreviewHistogram() }
            return autoreleasepool { calculatePhotoPreviewHistogram(image) }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }) {
        self.calculate = calculate
    }

    private func cancelPending() {
        task?.cancel()
        task = nil
        requestID = nil
        sourceImage = nil
        sourceFileID = nil
    }

    private func publish(_ next: Snapshot) {
        if snapshot != next { snapshot = next }
    }

    func clear() {
        cancelPending()
        publish(Snapshot())
    }

    func load(fileID: UInt32, image: UIImage) {
        // Android's produceState keys include the actual bitmap. Repeated
        // delivery of that same bitmap shares pending/completed analysis;
        // a replacement image of the same handle still starts a new request.
        if sourceImage === image && sourceFileID == fileID &&
            (task != nil || (snapshot.fileID == fileID && !bars.isEmpty)) { return }
        clear()
        sourceImage = image
        sourceFileID = fileID
        let id = UUID()
        requestID = id
        let calculate = calculate
        task = Task { [weak self] in
            let result = await calculate(image)
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.publish(Snapshot(result: result, fileID: fileID))
            self.task = nil
        }
    }

    func show(fileID: UInt32, cached: PhotoPreviewHistogram) {
        cancelPending()
        publish(Snapshot(result: cached, fileID: fileID))
    }

    deinit { task?.cancel() }
}

/// Keep ImageIO decoding off the main actor. ImageIO itself is synchronous;
/// cancellation discards its result before it can enter the page cache.
func loadCameraPhotoPreview(_ data: Data) async throws -> UIImage? {
    try await loadCameraPhotoPreviewContent(data)?.image
}

struct CameraPhotoPreviewContent: Sendable {
    let image: UIImage
    let histogram: PhotoPreviewHistogram?
    let orientation: Int?
}

/// Android review.loadPreview returns a decoded bitmap. Empty/invalid FHD
/// payloads therefore take the same one-time EndLiveView fallback as a read
/// error; a non-nil Data alone is not proof of a usable preview.
@MainActor
func loadRemoteReviewPreview(_ review: RemotePhotoReviewModel,
                             read: () async throws -> Data) async throws -> CameraPhotoPreviewContent? {
    try await review.preview {
        guard let data = try? await read(), !data.isEmpty else { return nil }
        return try? await loadCameraPhotoPreviewContent(data)
    }
}

func loadCameraPhotoPreviewContent(
    _ data: Data,
    decode: @escaping @Sendable (Data) -> CameraPhotoPreviewContent? = decodeCameraPhotoPreviewContent
) async throws -> CameraPhotoPreviewContent? {
    try Task.checkCancellation()
    let operation = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let result = autoreleasepool { decode(data) }
        try Task.checkCancellation()
        return result
    }
    return try await withTaskCancellationHandler {
        let image = try await operation.value
        try Task.checkCancellation()
        return image
    } onCancel: {
        operation.cancel()
    }
}

/// Synchronous codec boundary, called only from the detached worker above.
/// Separating it permits deterministic cancellation while the codec is busy.
private func decodeCameraPhotoPreviewContent(_ data: Data) -> CameraPhotoPreviewContent? {
    let histogram = decodePhotoPreviewAnalysisImage(data).map {
        calculatePhotoPreviewHistogram($0, sampleLimit: Int.max)
    }
    guard !Task.isCancelled, let image = decodeCameraPhotoPreview(data) else { return nil }
    return CameraPhotoPreviewContent(image: image, histogram: histogram,
        orientation: parseJpegCropOrientation(data))
}

/// Android previewHistogramFromJpeg: smallest power-of-two sample that brings
/// the long edge to <=512, followed by an exhaustive 8-bit sRGB analysis.
func decodePhotoPreviewAnalysisImage(_ data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0 else { return nil }
    let edge = max(width, height)
    var sample = 1
    while (edge + sample - 1) / sample > 512 { sample *= 2 }
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: false,
        kCGImageSourceThumbnailMaxPixelSize: (edge + sample - 1) / sample,
        kCGImageSourceShouldCacheImmediately: true
    ] as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

/// CameraViewModel.loadFhdPreview uses honorExifOrientation=false. Decode the
/// camera pixels without attaching EXIF rotation/mirroring to the UIImage;
/// the preview's shared manual rotation remains the only display transform.
func decodeCameraPhotoPreview(_ data: Data) -> UIImage? {
    let limit = 1920
    guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else { return nil }
    let longEdge = max(width, height)
    var sample = 1
    while longEdge / (sample * 2) >= limit { sample *= 2 }
    let decoded: CGImage?
    if sample > 1 {
        decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: (longEdge + sample - 1) / sample,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    } else {
        decoded = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    guard var image = decoded else { return nil }
    if max(image.width, image.height) > limit {
        let scale = Double(limit) / Double(max(image.width, image.height))
        let targetWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }
        image = scaled
    }
    return UIImage(cgImage: image, scale: 1, orientation: .up)
}

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
    let review: RemotePhotoReviewModel?
    let landscapeReview: Bool
    let effectsStore: PhotoEffectsStore?
    let effectsDirectory: DirectoryAccessStore?
    @State private var effectsFile: CameraFile?
    @State private var effectsPresented = false
    @State private var effectsRotation = 0
    let isSessionConnected: Bool
    let files: [CameraFile]
    private let projection: PhotoPreviewProjectionCache
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
    let onCropConfirmed: (CameraFile, JpegCropSelection) async -> Bool
    private let initialIndex: Int
    @State private var index: Int
    @State private var pagerSelection: Int
    @State private var pageFeedback = PhotoPreviewPageFeedback()
    private var pageOffsetFraction: CGFloat {
        get { pageFeedback.offset }
        nonmutating set { if pageFeedback.offset != newValue { pageFeedback.offset = newValue } }
    }
    @State private var exifLoadedAlpha: CGFloat = 0
    @State private var reviewRetry = 0
    @State private var reviewTap = PreviewReviewTapGuard()
    @State private var previewEntries: [PhotoPreviewEntry]
    @State private var rotationDegrees: Double = 0
    @State private var cropPresented = false
    @State private var cropEditor = PhotoCropEditingState()
    @State private var cropRestoring = false
    @State private var cropEnteredAt: TimeInterval = 0
    @State private var cropCloseTask: Task<Void, Never>?
    @StateObject private var cropPreparation = PhotoCropPreparation()
    private var preparedCrop: PreparedPhotoCrop? { cropPreparation.prepared }
    private var cropFailure: CropPreparationError? { cropPreparation.failure }
    @State private var cropRetry = 0
    @State private var cropLoadingVisible = false
    @State private var geometrySnapshot = PhotoPreviewGeometrySnapshot()
    private var currentCropViewport: PhotoPreviewCropViewport? {
        get { geometrySnapshot.viewport }
        nonmutating set { geometrySnapshot.viewport = newValue }
    }
    private var cropTop: CGFloat {
        if let queueTarget, queueTarget.midY < UIScreen.main.bounds.midY { return queueTarget.maxY + 20 }
        return previewSafeInsets.top + 62
    }
    @AppStorage("preview_rotation_quarter_turns") private var rotationQuarterTurns = 0
    @State private var previewSafeInsets = EdgeInsets()
    @State private var exif: PhotoExif?
    @State private var exifLoading = false
    // Android persists this switch in the transfer preference store, so it
    // survives leaving the preview and reopening the app.
    private var histogramPreferences = PhotoPreviewHistogramPreferences()
    private var histogramMode: RemoteHistogramMode { histogramPreferences.mode }
    private var histogramVisible: Bool { histogramMode != .off }
    @State private var histogram = PhotoPreviewHistogramModel()
    // The preview page publishes the bitmap it is already displaying. Keep
    // that reference so enabling the histogram never starts another camera
    // read or decodes the same image a second time.
    @State private var displayedImages: [UInt32: UIImage] = [:]
    @State private var highResolutionImages: [UInt32: UIImage] = [:]
    @State private var fhdOrientations: [UInt32: Int] = [:]
    @State private var fhdHistograms: [UInt32: PhotoPreviewHistogram] = [:]
    @State private var highResolutionLoading: Set<UInt32> = []
    @State private var fhdUnavailable: Set<UInt32> = []
    @State private var exifByFile: [UInt32: PhotoExif] = [:]
    @State private var exifFinished: Set<UInt32> = []
    @State private var deferredLoadsEnabled = false
    @State private var previousTransfersBusy = false
    @State private var neighborPrefetchTask: Task<Void, Never>?
    @State private var queueMotion = PhotoPreviewQueueMotion()
    private var queueDragOffset: CGFloat {
        get { queueMotion.offset }
        nonmutating set { if queueMotion.offset != newValue { queueMotion.offset = newValue } }
    }
    @State private var queueDragDirection: PhotoPreviewQueueDragDirection = .undecided
    @GestureState private var queueSwipeActive = false
    @State private var currentZoomed = false
    @State private var magnificationActive = false
    @State private var queueFlightTask: Task<Void, Never>?
    @State private var queueFlightActive = false
    @State private var queueFlightStartedAt: Date?
    @State private var queueFlightImage: UIImage?
    @State private var queueFlightImages: [UIImage?] = []
    @State private var queueFlightCount = 0
    @State private var queueFlightCropFrame: CGRect?
    @State private var queueFlightSourceFrame: CGRect?
    @State private var queueFlightRotation: Double = 0
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
    init(session: CameraSession, queueModel: TransferQueueViewModel, files: [CameraFile],
         projection: PhotoPreviewProjectionCache = PhotoPreviewProjectionCache(),
         review: RemotePhotoReviewModel? = nil,
         landscapeReview: Bool = false,
         effectsStore: PhotoEffectsStore? = nil, effectsDirectory: DirectoryAccessStore? = nil,
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
         onCropConfirmed: @escaping (CameraFile, JpegCropSelection) async -> Bool = { _, _ in false }) {
        self.queueModel = queueModel
        self.projection = projection
        self.effectsStore = effectsStore; self.effectsDirectory = effectsDirectory
        self.review = review
        self.landscapeReview = landscapeReview
        self.isSessionConnected = isSessionConnected
        self.session = session; self.files = files; self.directory = directory
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
        #if DEBUG
        ButtonInteractionTrace.recordNow("preview-init-begin")
        #endif
        let opening = projection.opening(
            files: files, burstIDByFile: burstIDByFile, collapseBursts: collapseBursts,
            expandedBurstIDs: initialExpandedBurstIDs, selectedFileID: selectedFile.wrappedValue?.id
        )
        _expandedBurstIDs = State(initialValue: initialExpandedBurstIDs)
        self.initialIndex = opening.index
        _previewEntries = State(initialValue: opening.entries)
        _index = State(initialValue: opening.index)
        _pagerSelection = State(initialValue: opening.index)
        _collapseAnchor = State(initialValue: initialAnchor)
        #if DEBUG
        ButtonInteractionTrace.recordNow("preview-init-end")
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.opacity((review == nil ? 0.74 : 1) * presentationProgress)
                .ignoresSafeArea(edges: review == nil ? .all : [])
            TabView(selection: $pagerSelection) {
                ForEach(previewPages) { page in
                    let itemIndex = page.index
                    let entry = page.entry
                    Group {
                        switch entry {
                        case .photo(let file, _):
                            PreviewImage(session: session, file: file,
                                         highResolutionImage: highResolutionImages[file.id],
                                         rotationDegrees: rotationDegrees,
                                         infoBottom: landscapeReview ? nil : previewSafeInsets.top + ((currentPhoto.map { burstIDByFile[$0.id] != nil || $0.isProtected } ?? false) ? 112 : 70),
                                         interactive: !closing && effectsFile == nil && !cropPresented && !cropRestoring && !queueFlightActive && !burstTransitionBusy && queueDragDirection != .upward,
                                         pinchEnabled: !closing && effectsFile == nil && !cropPresented && !cropRestoring && !queueFlightActive && !burstTransitionBusy,
                                         cropActive: cropPresented && itemIndex == index,
                                         cropTop: cropTop, cropEditor: cropEditor,
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
                                             guard photoPreviewHistogramCanAnalyze(
                                                enabled: histogramVisible, fileExtension: file.fileExtension
                                             ), currentPhoto?.id == file.id else { return }
                                             if let image {
                                                 showHistogram(for: file, image: image)
                                             } else {
                                                 histogram.clear()
                                             }
                                         }, onTap: {
                                             if review == nil || (reviewTap.allowed && abs(pageOffsetFraction) < 0.01 && !magnificationActive) {
                                                 startClose()
                                             }
                                         },
                                         onZoomedChange: { zoomed in if index == itemIndex, currentZoomed != zoomed { currentZoomed = zoomed } },
                                         onViewportChange: { viewport in
                                             if index == itemIndex { currentCropViewport = viewport }
                                         },
                                         onMagnificationChange: { active in
                                             guard index == itemIndex else { return }
                                             magnificationActive = active
                                             if active {
                                                 queueDragDirection = .rejected
                                                 settleQueueDrag()
                                             }
                                         },
                                         isCurrent: index == itemIndex, tapWhenZoomed: review != nil)
                                .padding(.bottom, landscapeReview ? 0 : previewSafeInsets.bottom + 88)
                        case .burst(let group):
                            BurstCollectionPreview(
                                session: session,
                                group: group,
                                loadEnabled: deferredLoadsEnabled && isSessionConnected,
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
                guard !closing, effectsFile == nil, !burstTransitionBusy,
                      let page = nearestPreviewPage(offsets: offsets),
                      previewEntries.indices.contains(page.index) else { return }
                // Observation changes current content at halfway; it never sends
                // a programmatic selection back into the moving TabView.
                if index != page.index { index = page.index }
                pageOffsetFraction = page.offset
            }
            .onChange(of: pagerSelection) { index = $0 }

            // Android's HorizontalPager owns the complete edge-to-edge stage;
            // only its controls apply system-bar padding. Center the image in
            // that same full-screen viewport instead of the reduced safe area.
            .ignoresSafeArea(edges: review == nil ? .all : [])
            .modifier(PhotoPreviewAnchorTransform(
                progress: presentationProgress,
                anchor: closing ? collapseAnchor : initialAnchor,
                enabled: closing ? collapseAnchor != nil : index == initialIndex,
                closing: closing
            ))
            .scaleEffect(burstPagerScale)
            .opacity(burstPagerAlpha)
            .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
            .modifier(PhotoPreviewQueueMotionTransform(motion: queueMotion))
            // Once an upward queue drag wins direction arbitration, cancel
            // the page scroll recognizer for the rest of this touch. A normal
            // horizontal drag keeps the pager enabled.
            .scrollDisabled(
                effectsFile != nil || cropPresented || cropRestoring || currentZoomed || magnificationActive || queueDragDirection == .upward ||
                    queueFlightActive || burstTransitionBusy
            )
            .allowsHitTesting(
                effectsFile == nil && !cropPresented && !cropRestoring && !queueFlightActive && !closing && !burstTransitionBusy &&
                    queueDragDirection != .upward
            )
            if queueFlightActive, previewEntries.indices.contains(index) {
                GeometryReader { proxy in
                    let screen = UIScreen.main.bounds
                    let resolvedTarget = queueTarget.flatMap { frame in
                        frame.isEmpty || frame.isInfinite || frame.isNull ? nil : frame
                    } ?? CGRect(x: screen.maxX - 13, y: 48, width: 1, height: 36)
                    let viewport = currentCropViewport
                    let placement = photoPreviewPlacement(imageSize: queueFlightImage?.size,
                        viewportSize: viewport?.size ?? proxy.size, rotationDegrees: rotationDegrees,
                        infoBottom: viewport?.infoBottom)
                    let square = min(proxy.size.width * 0.72, proxy.size.height * 0.46, 360)
                    let frame = queueFlightCropFrame ?? queueFlightSourceFrame ?? (queueFlightCount > 1
                        ? CGRect(x: (proxy.size.width - square) / 2, y: (proxy.size.height - square) / 2, width: square, height: square)
                        : CGRect(x: placement.center.x - placement.size.width / 2, y: placement.center.y - placement.size.height / 2,
                                 width: placement.size.width, height: placement.size.height))
                    let swapped = queueFlightCropFrame == nil && queueFlightCount == 1 && abs(Int((queueFlightRotation / 90).rounded())) % 2 == 1
                    PhotoPreviewQueueFlightView(
                        startedAt: queueFlightStartedAt,
                        image: queueFlightImage,
                        images: queueFlightImages,
                        from: CGPoint(x: frame.midX, y: frame.midY),
                        target: CGPoint(
                            // Match the list/Android landing point: the stable
                            // right edge of the carrier, inset into the capsule.
                            x: resolvedTarget.maxX - 28 - proxy.frame(in: .global).minX,
                            y: resolvedTarget.midY - proxy.frame(in: .global).minY
                        ),
                        size: swapped ? CGSize(width: frame.height, height: frame.width) : frame.size,
                        stackCount: queueFlightCount,
                        rotation: queueFlightCropFrame == nil && queueFlightCount == 1 ? queueFlightRotation : 0,
                        isCrop: queueFlightCropFrame != nil
                    )
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }
            if let file = currentPhoto {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        PreviewInfoText(text: reviewTitle(file))
                            .layoutPriority(1)
                            .modifier(PhotoPreviewInformationFade(feedback: pageFeedback, base: presentationProgress * burstPagerAlpha))
                            .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
                        if review == nil, let task = queueModel.task(for: file.id), task.status != .completed {
                            PhotoPreviewLiveTransferBadge(
                                task: task,
                                progressModel: queueModel.progressModel
                            )
                        } else if review == nil && transferredOriginal(file) { TransferredPhotoBadge() }
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(height: 36)
                    .padding(.trailing, review == nil ? 172 : 52)
                    Group {
                        if let exif { PreviewExifBar(exif: exif) }
                        else { Color.clear }
                    }
                    .frame(height: 26, alignment: .topLeading)
                    .modifier(PhotoPreviewInformationFade(feedback: pageFeedback, base: presentationProgress * burstPagerAlpha * exifLoadedAlpha))
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
                        .modifier(PhotoPreviewInformationFade(feedback: pageFeedback, base: presentationProgress * burstPagerAlpha))
                        .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
                    }
                }
                .opacity(cropPresented ? 0 : 1)
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18), value: cropPresented)
                .padding(.top, 6).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let file = currentPhoto, highResolutionLoading.contains(file.id) {
                RemoteReviewFHDLoading()
                    .opacity(presentationProgress * burstPagerAlpha * (cropPresented ? 0 : 1))
                    .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            PhotoPreviewTools(
                selection: currentPhoto.map { .init(file: $0,
                    canCollapse: photoPreviewCollectionIndex(previewEntries, memberIndex: index) != nil) },
                isReview: review != nil, effectsAvailable: effectsStore != nil && effectsDirectory != nil,
                effectsEnabled: effectsStore?.isEnabled == true, histogramMode: histogramMode,
                feedback: pageFeedback,
                inputsEnabled: !closing && effectsFile == nil && !cropPresented && !cropRestoring && !magnificationActive,
                editEnabled: !burstTransitionBusy && !queueFlightActive && queueDragDirection != .upward,
                collapseEnabled: !queueFlightActive && queueDragDirection != .upward && queueFlightTask == nil,
                rotationEnabled: !burstTransitionBusy,
                onCollapse: { collapseCurrentBurst() },
                onEffects: { file in
                    ZTransferHaptics.shared.play(.navigation)
                    effectsFile = file; effectsRotation = rotationQuarterTurns; effectsPresented = true
                },
                onCrop: { _ in
                    ZTransferHaptics.shared.play(.navigation)
                    cropPreparation.reset(); cropRetry = 0; cropLoadingVisible = false
                    cropCloseTask?.cancel(); cropEditor.reset()
                    cropEnteredAt = ProcessInfo.processInfo.systemUptime
                    withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) { cropPresented = true }
                },
                onHistogram: { histogramPreferences.mode = histogramMode.next },
                onRotate: {
                    // Accumulate angles so every press rotates counter-clockwise.
                    withAnimation(photoPreviewRotationAnimation) { rotationDegrees -= 90 }
                    rotationQuarterTurns = ((Int(-rotationDegrees / 90) % 4) + 4) % 4
                })
                .compositingGroup()
                .opacity(presentationProgress * burstPagerAlpha * (cropPresented ? 0 : 1))
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18), value: cropPresented)
                .offset(x: UIScreen.main.bounds.width * burstPagerSlide)
                .padding(.trailing, landscapeReview ? 12 : review != nil ? 20 : 76)
                .padding(.bottom, landscapeReview ? 8 : 32)
            PhotoPreviewHistogramLayer(model: histogram, mode: histogramMode,
                currentPhoto: currentPhoto, cropPresented: cropPresented,
                alpha: presentationProgress * burstPagerAlpha, feedback: pageFeedback,
                review: review != nil, landscapeReview: landscapeReview)
        }
        .overlayPreferenceValue(PreviewEffectsButtonAnchorKey.self) { anchor in
            if let anchor, let store = effectsStore, let directory = effectsDirectory, let file = effectsFile {
                Color.clear.allowsHitTesting(false).preference(key: PreviewPhotoEffectsPresentationKey.self,
                    value: PreviewPhotoEffectsEditor(isPresented: $effectsPresented, store: store, directory: directory,
                    source: highResolutionImages[file.id] ?? displayedImages[file.id],
                    exif: exifByFile[file.id], rotation: effectsRotation, anchor: anchor,
                    onDismissed: { if !effectsPresented { effectsFile = nil } }))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let review {
                let imageFailed = currentPhoto.map { fhdUnavailable.contains($0.id) } ?? false
                let pageFailed = index == previewEntries.count - 1 && review.failed
                if imageFailed || pageFailed || !isSessionConnected {
                    RemoteReviewRetryButton(connected: isSessionConnected) {
                        if imageFailed {
                            if let file = currentPhoto { fhdUnavailable.remove(file.id) }
                            reviewRetry += 1
                        }
                        if pageFailed { review.loadMore() }
                    }
                    .padding(.leading, 12).padding(.bottom, landscapeReview ? 8 : 32)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if let review, review.loading, index == previewEntries.count - 1 {
                RemoteCameraToolLoading(diameter: 20, strokeWidth: 2, color: .white).padding(12)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { previewSafeInsets = review == nil ? proxy.safeAreaInsets : EdgeInsets() }
                    .onChange(of: proxy.safeAreaInsets) { previewSafeInsets = review == nil ? $0 : EdgeInsets() }
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
        .overlay {
            if cropPresented, let file = currentPhoto {
                PhotoCropEditor(editor: cropEditor, confirming: cropPreparation.confirming,
                    loading: cropLoadingVisible, failure: cropFailure,
                    bottomClearance: previewSafeInsets.bottom + 32,
                    onRetry: { ZTransferHaptics.shared.play(.action); cropRetry += 1 },
                    onCancel: { ZTransferHaptics.shared.play(.action); closeCrop() })
                .ignoresSafeArea()
                .transition(.opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)))
                .task(id: "\(file.id)|\(cropRetry)") {
                    guard cropRetry > 0, highResolutionImages[file.id] == nil, isSessionConnected else { return }
                    fhdUnavailable.remove(file.id)
                    _ = await loadHighResolution(at: index, awaitExisting: true, allowCameraRequest: true)
                }
                .task(id: cropPreparationKey(file)) { await prepareCrop(file) }
                .task(id: "\(cropPreparationKey(file))|\(preparedCrop != nil)|\(cropFailure != nil)") {
                    cropLoadingVisible = false
                    guard preparedCrop == nil, cropFailure == nil else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { cropLoadingVisible = true }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if review == nil, let file = currentPhoto {
                PhotoPreviewQueueAction(editor: cropEditor, editing: cropPresented,
                    confirming: cropPreparation.confirming,
                    enabled: !closing && effectsFile == nil && !cropRestoring && !queueFlightActive && !burstTransitionBusy) {
                    if cropPresented { confirmCrop(file) } else { startQueueFlight(for: file) }
                }
                .padding(.trailing, 20).padding(.bottom, 32)
            }
        }
        // Keep the arbiter on the stable overlay rather than the TabView. The
        // TabView can therefore be disabled after an upward lock without
        // cancelling the gesture that owns the queue drag.
        .simultaneousGesture(previewQueueSwipeGesture)
        .onChange(of: queueSwipeActive) { active in
            // Android's awaitEachGesture finally block also runs on cancel.
            // SwiftUI onEnded does not: release the pager lock in both cases.
            if !active { finishQueueDrag() }
        }
        .background {
            if review != nil { PreviewReviewTouchObserver(state: reviewTap) }
        }
        .onAppear {
            #if DEBUG
            ButtonInteractionTrace.recordNow("preview-appear")
            #endif
            rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
            rotationDegrees = -90 * Double(rotationQuarterTurns)
            previousTransfersBusy = queueModel.snapshot.isTransferring
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.34)) {
                presentationProgress = 1
            }
        }
        .onDisappear {
            projection.clear()
            cropCloseTask?.cancel()
            cropPresented = false; cropRestoring = false
            cropPreparation.reset(); cropEditor.reset()
            histogram.clear()
            burstTransitionTask?.cancel()
            burstTransitionTask = nil
            neighborPrefetchTask?.cancel()
            neighborPrefetchTask = nil
            cancelQueueFlight()
        }
        .onChange(of: exif != nil) { loaded in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) {
                exifLoadedAlpha = loaded ? 1 : 0
            }
        }
        .onChange(of: currentEntryID) { _ in cancelQueueFlight() }
        .onChange(of: files) { updated in
            guard review != nil else { return }
            previewEntries = updated.map { .photo($0) }
            let bounded = min(index, max(0, updated.count - 1))
            if index != bounded { index = bounded; pagerSelection = bounded }
        }
        .onChange(of: index) { value in
            closeCrop()
            currentCropViewport = nil
            if previewEntries.indices.contains(value) {
                selectedFile = previewEntries[value].file ?? {
                    if case .burst(let group) = previewEntries[value] { return group.files.first }
                    return nil
                }()
                exif = nil
                exifLoading = false
                currentZoomed = false
                magnificationActive = false
                refreshHistogramForCurrentPhoto()
            }
        }
        .modifier(PhotoPreviewRetentionObserver(
            retainedIDs: retainedPhotoPreviewIDs(entries: previewEntries, currentIndex: index),
            trim: trimPreviewState))
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
            else { histogram.clear() }
        }
        .task {
            await session.setFHDActive(true)
            do {
                try await Task.sleep(nanoseconds: 340_000_000)
                guard !Task.isCancelled else { throw CancellationError() }
                if !closing { deferredLoadsEnabled = true }
                try await Task.sleep(nanoseconds: .max)
            } catch {}
            await session.setFHDActive(false)
        }
        .task(id: previewLoadIdentity) {
            guard deferredLoadsEnabled else { return }
            await loadCurrentThenNeighbors()
        }
    }

    private var currentEntryID: String? {
        guard previewEntries.indices.contains(index) else { return nil }
        return previewPages[index].id
    }

    private var previewProjection: PhotoPreviewProjectionCache.Pages {
        projection.pages(previewEntries, captureByHandle: review?.displaySnapshot.captureByHandle ?? [:])
    }

    private var previewPages: [PhotoPreviewPage] {
        previewProjection.values
    }

    private var currentPhoto: CameraFile? {
        guard previewEntries.indices.contains(index) else { return nil }
        return previewEntries[index].file
    }


    private func refreshHistogramForCurrentPhoto() {
        guard let file = currentPhoto,
              photoPreviewHistogramCanAnalyze(enabled: histogramVisible, fileExtension: file.fileExtension),
              let image = displayedImages[file.id] else { histogram.clear(); return }
        showHistogram(for: file, image: image)
    }

    private func showHistogram(for file: CameraFile, image: UIImage) {
        if let cached = fhdHistograms[file.id] {
            histogram.show(fileID: file.id, cached: cached)
        } else {
            histogram.load(fileID: file.id, image: image)
        }
    }

    private var previewQueueSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($queueSwipeActive) { _, active, _ in active = true }
            .onChanged { value in
                guard effectsFile == nil, !cropPresented, !cropRestoring else { return }
                guard review == nil, currentPhoto != nil, !currentZoomed, !magnificationActive,
                      effectsFile == nil, presentationProgress >= 0.99, abs(pageOffsetFraction) < 0.01, !queueFlightActive,
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
                defer { finishQueueDrag() }
                guard review == nil else { return }
                guard effectsFile == nil, !cropPresented, !cropRestoring else { return }
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

    private func finishQueueDrag() {
        queueDragDirection = .undecided
        if !queueFlightActive { settleQueueDrag() }
    }

    private func settleQueueDrag() {
        guard abs(queueDragOffset) >= 0.5 else {
            queueDragOffset = 0
            return
        }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 400, damping: 2 * 0.82 * sqrt(400))) {
            queueDragOffset = 0
        }
    }

    private func reviewTitle(_ file: CameraFile) -> String {
        guard let raw = review?.displaySnapshot.photosByPreferredHandle[file.id]?.pairedRawExtension else {
            return file.fileName
        }
        return file.fileName + " +" + raw.trimmingCharacters(in: CharacterSet(charactersIn: ".")).uppercased()
    }

    private func startClose() {
        if cropPresented { closeCrop(); return }
        guard !cropRestoring else { return }
        guard !closing, !burstTransitionBusy else { return }
        closing = true
        queueFlightTask?.cancel()
        queueFlightTask = nil
        if review != nil {
            // Android delegates review dismissal to the full black surface.
            // Do not fade this inner layer first or resume frame reads early.
            onDismiss(nil)
            return
        }
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

    private var previewLoadIdentity: PhotoPreviewLoadIdentity {
        PhotoPreviewLoadIdentity(entryIDs: previewProjection.loadIDs, index: index,
            deferredLoadsEnabled: deferredLoadsEnabled, connected: isSessionConnected, retry: reviewRetry)
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
        let metadata: PhotoExif?
        if let review, needsPreview {
            metadata = try? await session.withInteractivePreviewPriority {
                let content = try? await loadRemoteReviewPreview(review) { try await session.preview(handle: file.id) }
                await finishRemoteImageLoad(file: file, content: content)
                let (_, details) = await session.previewAndExif(file: file, loadPreview: false, loadExif: needsExif)
                return details
            }
        } else {
            (_, metadata) = await session.previewAndExif(
                file: file, loadPreview: needsPreview, loadExif: needsExif,
                onPreviewLoaded: { data in
                    await finishRemoteImageLoad(file: file, data: data)
                }
            )
        }
        highResolutionLoading.remove(file.id)
        guard !Task.isCancelled else { return }
        finishRemoteExifLoad(file: file, metadata: metadata, loadedExif: needsExif)
        guard !Task.isCancelled else { return }
        if review != nil && index >= previewEntries.count - 3 { review?.loadMore() }
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
        let decoded: CameraPhotoPreviewContent?
        if let review { decoded = try? await loadRemoteReviewPreview(review) { try await session.preview(handle: id) } }
        else if let data = try? await session.preview(handle: id) { decoded = try? await loadCameraPhotoPreviewContent(data) }
        else { decoded = nil }
        guard let content = decoded,
              !Task.isCancelled else {
            if !Task.isCancelled { fhdUnavailable.insert(id) }
            return false
        }
        // A page change can trim this handle while its synchronous codec is
        // finishing. Recheck the live retention window before repopulating it.
        guard retainedPhotoPreviewIDs(entries: previewEntries, currentIndex: index).contains(id) else { return false }
        fhdOrientations[id] = content.orientation
        fhdHistograms[id] = content.histogram
        highResolutionImages[id] = content.image
        displayedImages[id] = content.image
        fhdUnavailable.remove(id)
        return true
    }

    @MainActor
    private func finishRemoteImageLoad(file: CameraFile, data: Data?) async {
        let content: CameraPhotoPreviewContent?
        if let data { content = try? await loadCameraPhotoPreviewContent(data) }
        else { content = nil }
        finishRemoteImageLoad(file: file, content: content)
    }

    @MainActor
    private func finishRemoteImageLoad(file: CameraFile, content: CameraPhotoPreviewContent?) {
        guard !Task.isCancelled,
              retainedPhotoPreviewIDs(entries: previewEntries, currentIndex: index).contains(file.id) else { return }
        if let content {
            fhdOrientations[file.id] = content.orientation
            fhdHistograms[file.id] = content.histogram
            highResolutionImages[file.id] = content.image
            displayedImages[file.id] = content.image
            fhdUnavailable.remove(file.id)
            ZTransferHaptics.shared.play(.contentReady)
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
        fhdOrientations = fhdOrientations.filter { keep.contains($0.key) }
        fhdHistograms = fhdHistograms.filter { keep.contains($0.key) }
        displayedImages = displayedImages.filter { keep.contains($0.key) }
        fhdUnavailable.formIntersection(keep)
        exifByFile = exifByFile.filter { keep.contains($0.key) }
        exifFinished.formIntersection(keep)
    }

    private func cropPreparationKey(_ file: CameraFile) -> String {
        "\(file.id)|\(cropRetry)|\(highResolutionImages[file.id] != nil)|\(fhdUnavailable.contains(file.id))|\(isSessionConnected)"
    }

    @MainActor
    private func prepareCrop(_ file: CameraFile) async {
        guard cropEditor.geometry == nil else { return }
        let prepared: PreparedPhotoCrop?
        if let cached = preparedCrop { prepared = cached }
        else { prepared = await cropPreparation.load({
            try Task.checkCancellation()
            guard let image = highResolutionImages[file.id] else {
                if !isSessionConnected { throw CropPreparationError.connection() }
                if fhdUnavailable.contains(file.id) { throw CropPreparationError.previewRead() }
                return nil // The existing page load will restart this task when FHD arrives.
            }
            let orientation = try await cropPreparationOrientation(
                cached: exifByFile[file.id]?.orientation, connected: isSessionConnected) {
                    try await session.readPrefix(file: file, length: 128 * 1024, retryDeviceBusy: true)
                }
            try Task.checkCancellation()
            let embedded = fhdOrientations[file.id]
            let rotation = rotationDegrees
            let operation = Task.detached(priority: .userInitiated) {
                try preparePhotoCrop(image: image, orientation: orientation,
                    embeddedOrientation: embedded, rotation: rotation)
            }
            return try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
        }) }
        guard let prepared, !Task.isCancelled, cropPresented, currentPhoto?.id == file.id else { return }
        let corrected = prepared.preview.correctedRotation(from: rotationDegrees)
        let rotationChanged = corrected != rotationDegrees
        if rotationChanged {
            withAnimation(photoPreviewRotationAnimation) { rotationDegrees = corrected }
            rotationQuarterTurns = ((Int(-corrected / 90) % 4) + 4) % 4
            currentZoomed = false
        }
        // Android waits for the entry layout, and only adds 240ms when it
        // corrects orientation. A slow FHD read must not add another fixed wait.
        let remaining = rotationChanged ? 0.24 : max(0, cropEnteredAt + 0.22 - ProcessInfo.processInfo.systemUptime)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        await Task.yield()
        guard !Task.isCancelled, cropPresented, currentPhoto?.id == file.id,
              let viewport = currentCropViewport else { return }
        let placement = photoPreviewPlacement(imageSize: CGSize(width: prepared.preview.imageWidth,
            height: prepared.preview.imageHeight), viewportSize: viewport.size,
            rotationDegrees: corrected, infoBottom: viewport.infoBottom, cropTop: cropTop, cropProgress: 1)
        let frame = CGRect(x: placement.center.x - placement.size.width / 2,
            y: placement.center.y - placement.size.height / 2, width: placement.size.width, height: placement.size.height)
        try? cropEditor.begin(preview: prepared.preview,
            placement: CropImagePlacement(image: frame, viewport: viewport.size, rotation: corrected))
    }

    private func closeCrop() {
        guard cropPresented else { return }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) { cropPresented = false }
        cropRestoring = true
        cropCloseTask?.cancel()
        cropCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            cropPreparation.reset()
            cropEditor.reset()
            cropRestoring = false
        }
    }

    private func confirmCrop(_ file: CameraFile) {
        guard let selection = cropEditor.selection, let prepared = preparedCrop,
              let geometry = cropEditor.geometry else { return }
        Task { @MainActor in
            let accepted = await cropPreparation.confirm(selection: selection) { selection in
                return await onCropConfirmed(file, selection)
            }
            guard accepted, cropPresented, currentPhoto?.id == file.id else { return }
            let bounds = selection.bounds
            let source = prepared.image.cgImage
            let rect = CGRect(x: bounds.left * Double(source?.width ?? 0), y: bounds.top * Double(source?.height ?? 0),
                width: (bounds.right - bounds.left) * Double(source?.width ?? 0), height: (bounds.bottom - bounds.top) * Double(source?.height ?? 0))
            let image = source?.cropping(to: rect).map { UIImage(cgImage: $0) }
            startQueueFlight(for: file, acceptedCrop: (image, geometry.frame))
            closeCrop()
        }
    }

    private func isVideo(_ file: CameraFile) -> Bool {
        [".mov", ".mp4"].contains(file.fileExtension.lowercased())
    }

    private func isJPEG(_ file: CameraFile) -> Bool {
        [".jpg", ".jpeg"].contains(file.fileExtension.lowercased())
    }

    private func transferredOriginal(_ file: CameraFile) -> Bool {
        // FileListScreen passes the current destination index to the preview.
        // Task completion and an opening-time URL are not current file presence.
        transferredFileIDs.contains(file.id)
    }

    private func collapseCurrentBurst() {
        guard !closing, effectsFile == nil, !burstTransitionBusy, !queueFlightActive,
              abs(queueDragOffset) < 0.5 else { return }
        guard let collectionIndex = photoPreviewCollectionIndex(previewEntries, memberIndex: index),
              case let .burst(group) = previewEntries[collectionIndex] else { return }
        burstTransitionBusy = true
        animatedBurstID = group.id
        ZTransferHaptics.shared.play(.navigation)
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
        guard !closing, effectsFile == nil, !burstTransitionBusy, !group.files.isEmpty else { return }
        guard let collectionIndex = previewEntries.firstIndex(where: { entry in
            if case .burst(let value) = entry { return value.id == group.id }
            return false
        }), index == collectionIndex else { return }
        burstTransitionBusy = true
        animatedBurstID = group.id
        ZTransferHaptics.shared.play(.navigation)
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

    /// Android's current-item effect and disposal both settle the old flight.
    private func cancelQueueFlight() {
        queueFlightTask?.cancel()
        queueFlightTask = nil
        let cancelledCount = queueFlightCount
        queueFlightCount = 0
        queueFlightActive = false
        queueDragOffset = 0
        queueFlightStartedAt = nil
        queueFlightImage = nil
        queueFlightImages = []
        queueFlightCropFrame = nil; queueFlightSourceFrame = nil
        // Match Android's finally cleanup before notifying the parent.
        // A retained preview must be able to admit another flight on return.
        if cancelledCount > 0 { onQueueFlightCancelled(cancelledCount) }
    }

    private func startQueueFlight(for file: CameraFile, burstFiles: [CameraFile]? = nil, acceptedCrop: (UIImage?, CGRect)? = nil) {
        guard review == nil, !closing, !burstTransitionBusy, !queueFlightActive else { return }
        let flightCount = burstFiles?.count ?? 1
        // Android admits the real task before acquiring a visual hold.
        // A rejected enqueue must not publish transient queue state.
        guard acceptedCrop != nil || (burstFiles.map(onEnqueueBurst) ?? onEnqueue(file)) else { return }
        onQueueFlightStarted(flightCount)
        ZTransferHaptics.shared.play(.enqueue)
        queueFlightCount = flightCount
        queueFlightActive = true
        queueFlightStartedAt = Date().addingTimeInterval(0.032)
        let flightFiles = burstFiles?.prefix(3).map { $0 } ?? [file]
        queueFlightImages = flightFiles.map { displayedImages[$0.id] ?? session.memoryThumbnailImage(file: $0) }
        queueFlightImage = acceptedCrop?.0 ?? highResolutionImages[file.id] ?? displayedImages[file.id]
            ?? queueFlightImages.compactMap { $0 }.first
        queueFlightCropFrame = acceptedCrop?.1
        queueFlightRotation = rotationDegrees
        queueFlightSourceFrame = nil
        if acceptedCrop == nil, burstFiles == nil, let viewport = currentCropViewport {
            let placement = photoPreviewPlacement(imageSize: queueFlightImage?.size, viewportSize: viewport.size,
                rotationDegrees: rotationDegrees, infoBottom: viewport.infoBottom)
            let size = CGSize(width: placement.size.width * viewport.scale, height: placement.size.height * viewport.scale)
            queueFlightSourceFrame = CGRect(x: placement.center.x + viewport.offset.width - size.width / 2,
                y: placement.center.y + viewport.offset.height - size.height / 2, width: size.width, height: size.height)
        }
        let riseDuration: UInt64 = queueDragOffset < -1 ? 105_000_000 : 155_000_000
        withAnimation(.timingCurve(
            0.4, 0.0, 0.2, 1.0,
            duration: Double(riseDuration) / 1_000_000_000
        )) {
            if acceptedCrop == nil { queueDragOffset = -132 }
        }
        queueFlightTask?.cancel()
        queueFlightTask = Task { @MainActor in
            // Cancellation can precede the first actor turn, before any sleep.
            guard !Task.isCancelled, queueFlightActive else { return }
            // The immutable start time already includes Android's 32 ms
            // preroll. Wait for the complete rise before issuing the return.
            try? await Task.sleep(nanoseconds: riseDuration)
            guard !Task.isCancelled, queueFlightActive else { return }
            withAnimation(.interpolatingSpring(mass: 1, stiffness: 1500, damping: 2 * 0.78 * sqrt(1500))) {
                queueDragOffset = 0
            }
            try? await Task.sleep(nanoseconds: 592_000_000 - riseDuration)
            guard !Task.isCancelled else { return }
            queueDragOffset = 0
            queueFlightActive = false
            queueFlightCount = 0
            queueFlightStartedAt = nil; queueFlightImage = nil; queueFlightImages = []
            queueFlightCropFrame = nil; queueFlightSourceFrame = nil
            queueFlightTask = nil
            onQueueFlightFinished(flightCount)
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

/// Collections have no source; video covers must not be analysed as photos.
/// This affects eligibility only and never changes the saved user preference.
func photoPreviewHistogramCanAnalyze(enabled: Bool, fileExtension: String?) -> Bool {
    guard enabled, let fileExtension else { return false }
    return ![".mov", ".mp4"].contains(fileExtension.lowercased())
}

func photoPreviewHistogramOverlayVisible(
    enabled: Bool,
    currentPhotoID: UInt32?,
    histogramFileID: UInt32?,
    binCount: Int
) -> Bool {
    enabled && currentPhotoID != nil && currentPhotoID == histogramFileID && binCount > 0
}

struct PhotoPreviewHistogram: Equatable, Sendable {
    var luma: [CGFloat] = []
    var rgb: [[CGFloat]] = []
}

func previewLuminanceHistogram(_ image: UIImage) -> [CGFloat] {
    calculatePhotoPreviewHistogram(image).luma
}

/// Match Android's regular grid sampling; resizing would average tiny highlights.
func calculatePhotoPreviewHistogram(_ image: UIImage, sampleLimit: Int = 24_000) -> PhotoPreviewHistogram {
    guard let cg = image.cgImage else { return PhotoPreviewHistogram() }
    let width = cg.width, height = cg.height
    let step = max(1, Int(ceil(sqrt(Double(width) * Double(height) / Double(max(1, sampleLimit))))))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return PhotoPreviewHistogram() }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    var bins = [Int](repeating: 0, count: 256)
    var channels = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
    for y in stride(from: 0, to: height, by: step) {
        for x in stride(from: 0, to: width, by: step) {
            let offset = (y * width + x) * 4
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            bins[(54 * r + 183 * g + 19 * b) >> 8] += 1
            channels[0][r] += 1; channels[1][g] += 1; channels[2][b] += 1
        }
    }
    let peak = CGFloat(max(1, bins.max() ?? 1))
    let rgbPeak = CGFloat(max(1, channels.flatMap { $0 }.max() ?? 1))
    return PhotoPreviewHistogram(luma: bins.map { CGFloat($0) / peak },
                                rgb: channels.map { $0.map { CGFloat($0) / rgbPeak } })
}

/// Analysis results invalidate only this overlay, never the pager, EXIF,
/// cropping or transfer controls. The previous opacity/transition stays local.
struct PhotoPreviewHistogramLayer: View {
    @ObservedObject var model: PhotoPreviewHistogramModel
    let mode: RemoteHistogramMode
    let currentPhoto: CameraFile?
    let cropPresented: Bool
    let alpha: CGFloat
    let feedback: PhotoPreviewPageFeedback
    var review = false
    var landscapeReview = false
    #if DEBUG
    var didRender: ((Bool) -> Void)? = nil
    #endif
    var body: some View {
        let visible = photoPreviewHistogramOverlayVisible(
            enabled: photoPreviewHistogramCanAnalyze(enabled: mode != .off, fileExtension: currentPhoto?.fileExtension),
            currentPhotoID: currentPhoto?.id, histogramFileID: model.fileID, binCount: model.bars.count)
        #if DEBUG
        let _ = didRender?(visible)
        #endif
        if !model.bars.isEmpty {
            PreviewHistogramOverlay(values: model.bars, rgb: model.result.rgb, mode: mode)
                .padding(.leading, landscapeReview ? 12 : 20)
                .padding(.bottom, landscapeReview ? 8 : review ? 72 : 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .modifier(PhotoPreviewInformationFade(feedback: feedback, base: visible && !cropPresented ? alpha : 0))
                .animation(.easeInOut(duration: 0.18), value: visible)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

/// Android's shared 118x62 histogram: 256-bin filled luminance curve, bright
/// outline and a faint baseline. This is intentionally not a bar chart.
struct PreviewHistogramOverlay: View {
    let values: [CGFloat]
    let rgb: [[CGFloat]]?
    let mode: RemoteHistogramMode

    var body: some View {
        AndroidBooleanCrossfade(selected: mode == .rgb, durationMilliseconds: 180) { showRGB in
            if showRGB { PreviewRGBHistogram(values: values, rgb: rgb) }
            else { PreviewLuminanceHistogram(values: values) }
        }
        .frame(width: 118, height: 62)
        .allowsHitTesting(false)
    }
}

/// RemoteMonitorScopes.ScopeCard/MonitorHistogramOverlay: centres of bins,
/// additive filled channels, separate contour (never stroke the closing edges).
private struct PreviewRGBHistogram: View {
    let values: [CGFloat]
    let rgb: [[CGFloat]]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("RGB").font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                Text("0–255").font(.system(size: 7, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
            .frame(height: 10)
            Canvas { surface, size in
                // Grid and channels share one offscreen layer; Plus adds to
                // the grid as well, while the translucent card stays outside.
                surface.drawLayer { context in
                let height = max(1, size.height - 2)
                for index in 0..<5 {
                    let x = size.width * CGFloat(index) / 4
                    var line = Path(); line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                }
                do {
                    var channelsContext = context
                    channelsContext.blendMode = .plusLighter
                    let channels = rgb?.count == 3 ? rgb! : [values]
                    let colors = [Color(red: 1, green: 48/255, blue: 48/255),
                                  Color(red: 48/255, green: 239/255, blue: 48/255),
                                  Color(red: 64/255, green: 64/255, blue: 1)]
                    for (channel, bins) in channels.enumerated() where !bins.isEmpty {
                        var contour = Path()
                        for (index, value) in bins.enumerated() {
                            let y = height * (1 - min(1, max(0, value)))
                            if index == 0 { contour.move(to: CGPoint(x: 0, y: y)) }
                            contour.addLine(to: CGPoint(x: size.width * (CGFloat(index) + 0.5) / CGFloat(bins.count), y: y))
                        }
                        contour.addLine(to: CGPoint(x: size.width, y: height * (1 - min(1, max(0, bins.last ?? 0)))))
                        var fill = contour
                        fill.addLine(to: CGPoint(x: size.width, y: height))
                        fill.addLine(to: CGPoint(x: 0, y: height)); fill.closeSubpath()
                        let color = channels.count == 3 ? colors[channel] : Color(red: 228/255, green: 235/255, blue: 231/255)
                        channelsContext.fill(fill, with: .color(color.opacity(0.34)))
                        channelsContext.stroke(contour, with: .color(color.opacity(0.62)), lineWidth: 0.65)
                    }
                }
                var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: height))
                baseline.addLine(to: CGPoint(x: size.width, y: height))
                context.stroke(baseline, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
                }
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

private struct PreviewLuminanceHistogram: View {
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
    let rotation: Double
    let isCrop: Bool

    var body: some View {
        let count = stackCount > 1 ? min(stackCount, 3) : 1
        let specs = (0..<count).map { layer in
            QueueFlightLayerSpec(image: count > 1 ? (images.indices.contains(layer) ? images[layer] : nil) : image,
                size: size, corner: count > 1 ? 12 : 0, borderAlpha: count > 1 ? 0.32 : 0,
                background: count > 1 ? UIColor.white.withAlphaComponent(0.14) : .clear,
                aspectFill: count > 1)
        }
        if let startedAt {
            QueueFlightLayers(startedAt: startedAt, duration: 0.56, specs: specs) { elapsed in
                let p = queueFlightEasedProgress(CGFloat(min(max(elapsed / 0.56, 0), 1)))
                let center = queueFlightPoint(progress: p, start: from, end: target)
                let initial: CGFloat = isCrop ? 1 : 0.82
                let scale = initial + (18 / max(max(size.width, size.height), 1) - initial) * p
                let angle: CGFloat = CGFloat(rotation) + (isCrop ? 0 : 2.2 * sin(.pi * p))
                let alpha = min(p / 0.12, 1) * (p > 0.94 ? (1 - p) / 0.06 : 1) * (isCrop ? 1 : count > 1 ? 0.86 : 0.82)
                return (0..<count).map { layer in
                    let dx: CGFloat = count > 1 ? CGFloat(layer - 1) * 12 : 0
                    let dy: CGFloat = count > 1 ? CGFloat(1 - layer) * 5 : 0
                    let rad = angle * .pi / 180
                    return QueueFlightLayerFrame(center: CGPoint(x: center.x + (dx * cos(rad) - dy * sin(rad)) * scale,
                        y: center.y + (dx * sin(rad) + dy * cos(rad)) * scale), scale: scale,
                        rotation: angle + (count > 1 ? CGFloat(layer - 1) * 9 : 0), alpha: alpha)
                }
            }
        }
    }
}

struct PhotoPreviewToolSelection: Equatable {
    let file: CameraFile
    let canCollapse: Bool
}

struct PhotoPreviewToolLayout {
    let size: CGFloat
    let gap: CGFloat
    init(width: CGFloat, effects: Bool, collapse: Bool) {
        let count = CGFloat(3 + (effects ? 1 : 0) + (collapse ? 1 : 0))
        gap = min(12, max(4, (width - 44 * count) / (count - 1)))
        size = min(44, max(0, (width - gap * (count - 1)) / count))
    }
}

/// PhotoPreview.PreviewPhotoActionVisibility: retain the button AND its trailing
/// gap through fade-out. A Boolean crossfade with an empty false branch gives
/// the same fixed-size slot without scale/expand transitions or parent ticks.
struct PreviewActionVisibility<Content: View>: View {
    let visible: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        AndroidBooleanCrossfade(selected: visible, durationMilliseconds: 180) { showing in
            if showing { content().compositingGroup() }
        }
    }
}

struct PhotoPreviewTools: View {
    let selection: PhotoPreviewToolSelection?
    let isReview: Bool
    let effectsAvailable: Bool
    let effectsEnabled: Bool
    let histogramMode: RemoteHistogramMode
    let feedback: PhotoPreviewPageFeedback
    let inputsEnabled: Bool
    let editEnabled: Bool
    let collapseEnabled: Bool
    let rotationEnabled: Bool
    let onCollapse: () -> Void
    let onEffects: (CameraFile) -> Void
    let onCrop: (CameraFile) -> Void
    let onHistogram: () -> Void
    let onRotate: () -> Void
    @State private var retained: PhotoPreviewToolSelection?

    private func accepts(_ file: CameraFile) -> Bool {
        inputsEnabled && selection?.file.id == file.id && abs(feedback.offset) < 0.01
    }
    var body: some View {
        GeometryReader { geometry in
            PreviewActionVisibility(visible: selection != nil) {
                if let item = selection ?? retained {
                    let file = item.file
                    let metrics = PhotoPreviewToolLayout(width: geometry.size.width,
                        effects: effectsAvailable && effectsEnabled, collapse: item.canCollapse)
                    let effects = effectsAvailable && showPreviewPhotoEffects(enabled: effectsEnabled,
                                                                               isReview: isReview, file: file)
                    let crop = !isReview && [".jpg", ".jpeg"].contains(file.fileExtension.lowercased())
                    let image = ![".mov", ".mp4"].contains(file.fileExtension.lowercased())
                    HStack(spacing: 0) {
                        if item.canCollapse {
                            PreviewCircleButton(icon: .collapse, accessibilityKey: "cd_collapse", size: metrics.size) {
                                if accepts(file) && collapseEnabled { onCollapse() }
                            }
                            .disabled(!inputsEnabled || !collapseEnabled)
                            .padding(.trailing, metrics.gap)
                        }
                        PreviewActionVisibility(visible: effects) {
                            Button { if effects && accepts(file) && editEnabled { onEffects(file) } } label: {
                                QueueBadgeIcon(state: .generating).fill(ZTransferColors.accentOrange)
                                    .frame(width: 20, height: 20).frame(width: metrics.size, height: metrics.size)
                            }
                            .accessibilityLabel(AppLocalized.resource("photo_effects_open_editor"))
                            .anchorPreference(key: PreviewEffectsButtonAnchorKey.self, value: .bounds) { $0 }
                            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: metrics.size / 2))
                            .padding(.trailing, metrics.gap)
                        }
                        PreviewActionVisibility(visible: crop) {
                            PreviewCircleButton(icon: .crop, accessibilityKey: "crop_title", size: metrics.size) {
                                if crop && accepts(file) && editEnabled { onCrop(file) }
                            }
                            .padding(.trailing, metrics.gap)
                        }
                        PreviewActionVisibility(visible: image) {
                            HStack(spacing: metrics.gap) {
                                PreviewCircleButton(icon: .histogram, accessibilityKey: "cd_preview_histogram",
                                    active: histogramMode != .off, histogramRGB: histogramMode == .rgb, size: metrics.size) {
                                    if image && accepts(file) { onHistogram() }
                                }
                                PreviewCircleButton(icon: .rotateLeft, accessibilityKey: "cd_rotate_photo", size: metrics.size) {
                                    if image && accepts(file) && rotationEnabled { onRotate() }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .onAppear { if let selection { retained = selection } }
        .onChange(of: selection) { if let selection = $0 { retained = selection } }
    }
}

enum PreviewControlIcon: Equatable {
    case collapse, expand, histogram, rotateLeft, crop, add, check, close
}

struct PreviewCircleButton: View {
    let icon: PreviewControlIcon
    let accessibilityKey: String
    var active = false
    var histogramRGB = false
    var size: CGFloat = 44
    var tint: Color = ZTransferColors.accentBlue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PreviewControlMark(icon: icon, tint: tint, histogramRGB: histogramRGB)
                .frame(width: markSize, height: markSize)
                .foregroundStyle(tint)
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
        case .histogram, .crop: return 20
        case .rotateLeft, .add, .check, .close: return size * 0.5
        }
    }
}

/// Code-drawn copies of the Android Material/control marks. SF Symbols use a
/// different taper, optical width and bar count, which is obvious when the
/// four controls are stacked together.
struct PreviewControlMark: View {
    let icon: PreviewControlIcon
    var tint: Color = ZTransferColors.accentBlue
    var histogramRGB = false

    var body: some View {
        Canvas { context, size in
            let tint = GraphicsContext.Shading.color(tint)
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
                        with: histogramRGB ? .color(RemoteToolMark.rgb[min(index * 3 / 5, 2)]) : tint,
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
                // Material 1.5.4 filled CropKt, verified against the Android
                // dependency bytecode: two separate L paths and rounded joints.
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
                var crop = Path()
                crop.move(to: p(17, 15)); crop.addLine(to: p(19, 15)); crop.addLine(to: p(19, 7))
                crop.addCurve(to: p(17, 5), control1: p(19, 5.9), control2: p(18.1, 5))
                crop.addLine(to: p(9, 5)); crop.addLine(to: p(9, 7)); crop.addLine(to: p(17, 7)); crop.closeSubpath()
                crop.move(to: p(7, 17)); crop.addLine(to: p(7, 1)); crop.addLine(to: p(5, 1))
                crop.addLine(to: p(5, 5)); crop.addLine(to: p(1, 5)); crop.addLine(to: p(1, 7)); crop.addLine(to: p(5, 7))
                crop.addLine(to: p(5, 17))
                crop.addCurve(to: p(7, 19), control1: p(5, 18.1), control2: p(5.9, 19))
                crop.addLine(to: p(17, 19)); crop.addLine(to: p(17, 23)); crop.addLine(to: p(19, 23))
                crop.addLine(to: p(19, 19)); crop.addLine(to: p(23, 19)); crop.addLine(to: p(23, 17)); crop.closeSubpath()
                context.fill(crop, with: tint)
            case .check, .close:
                let scale = min(size.width, size.height) / 24
                let points: [CGPoint] = icon == .check
                    ? [CGPoint(x: 9, y: 16.17), CGPoint(x: 4.83, y: 12), CGPoint(x: 3.41, y: 13.41), CGPoint(x: 9, y: 19), CGPoint(x: 21, y: 7), CGPoint(x: 19.59, y: 5.59)]
                    : [CGPoint(x: 19, y: 6.41), CGPoint(x: 17.59, y: 5), CGPoint(x: 12, y: 10.59), CGPoint(x: 6.41, y: 5), CGPoint(x: 5, y: 6.41), CGPoint(x: 10.59, y: 12), CGPoint(x: 5, y: 17.59), CGPoint(x: 6.41, y: 19), CGPoint(x: 12, y: 13.41), CGPoint(x: 17.59, y: 19), CGPoint(x: 19, y: 17.59), CGPoint(x: 13.41, y: 12)]
                var path = Path()
                path.addLines(points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }); path.closeSubpath()
                context.fill(path, with: tint)
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
    let loadEnabled: Bool
    let stackMotion: CGFloat
    let onTransfer: () -> Void
    let onExpand: () -> Void
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * 0.72, proxy.size.height * 0.46)
            ZStack {
                // The whole collection stage closes, while the controls above
                // this background retain their own actions.
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onTap)
                ZStack {
                    ForEach(Array(group.files.prefix(3).reversed().enumerated()), id: \.element.id) { index, file in
                        let last = min(2, group.files.count - 1)
                        let spread: CGFloat = index == last ? 0 : (index.isMultiple(of: 2) ? -1 : 1)
                        BurstPreviewThumbnail(session: session, file: file, loadEnabled: loadEnabled)
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

private struct BurstPreviewThumbnail: View {
    let session: CameraSession
    let file: CameraFile
    let loadEnabled: Bool
    @State private var image: UIImage?

    init(session: CameraSession, file: CameraFile, loadEnabled: Bool) {
        self.session = session
        self.file = file
        self.loadEnabled = loadEnabled
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
        .task(id: file.id) {
            // Observe cache publication even when loading is gated or STA owns
            // the ordered fill queue. Subscription itself performs no fetch.
            for await _ in await session.thumbnailUpdates(handle: file.id) {
                guard !Task.isCancelled else { return }
                if let cached = try? await session.thumbnailImage(file: file, allowRemote: false) {
                    guard !Task.isCancelled else { return }
                    image = cached
                }
            }
        }
        .task(id: loadEnabled) {
            guard loadEnabled, session.wirelessMode != .sta, image == nil else { return }
            if let loaded = try? await session.thumbnailImage(file: file, allowRemote: true) {
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }
}

private struct PreviewImage: View {
    let session: CameraSession
    let file: CameraFile
    let highResolutionImage: UIImage?
    let rotationDegrees: Double
    let infoBottom: CGFloat?
    let interactive: Bool
    // Keep observing a second finger during an upward queue drag so it can
    // reject that drag, as Android's pressedCount > 1 guard does.
    let pinchEnabled: Bool
    let cropActive: Bool
    let cropTop: CGFloat
    let cropEditor: PhotoCropEditingState
    let zoomEnabled: Bool
    let loadEnabled: Bool
    let allowRemoteThumbnailFallback: Bool
    let onDisplayImage: (UIImage?) -> Void
    let onTap: () -> Void
    let onZoomedChange: (Bool) -> Void
    let onViewportChange: (PhotoPreviewCropViewport) -> Void
    let onMagnificationChange: (Bool) -> Void
    let isCurrent: Bool
    var tapWhenZoomed = false
    @State private var thumbnail: UIImage?
    @State private var remoteThumbnailUnavailable = false
    @State private var highResolutionAlpha: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureStartScale: CGFloat = 1
    @State private var gestureStartOffset: CGSize = .zero
    @GestureState private var panActive = false
    @State private var zoomAnimationTask: Task<Void, Never>?
    @State private var zoomAnimationActive = false
    @State private var magnifying = false
    @State private var cropProgress: CGFloat = 0
    @State private var cropReturnScale: CGFloat = 1
    @State private var cropReturnOffset: CGSize = .zero

    var body: some View {
        let cachedThumbnail = thumbnail ?? session.memoryThumbnailImage(file: file)
        GeometryReader { proxy in
            let cropViewport = PhotoPreviewCropViewport(size: proxy.size, scale: scale, offset: offset,
                rotation: rotationDegrees, infoBottom: infoBottom ?? 0)
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
                zoomScale: scale, cropTop: cropTop, cropProgress: cropProgress
            ))
            .offset(offset)
            .modifier(PhotoCropImageTransform(editor: cropEditor, active: cropActive))
            .simultaneousGesture(panGesture(
                viewportSize: proxy.size,
                imageSize: (highResolutionImage ?? cachedThumbnail)?.size
            ), including: zoomEnabled && scale > 1.01 ? .all : .none)
            .simultaneousGesture(tapGesture(
                viewportSize: proxy.size,
                imageSize: (highResolutionImage ?? cachedThumbnail)?.size
            ))
            .overlay {
                PreviewPinchObserver(enabled: pinchEnabled && zoomEnabled && isCurrent && (highResolutionImage ?? cachedThumbnail) != nil,
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
            .onAppear { if isCurrent { onViewportChange(cropViewport) } }
            .onChange(of: cropViewport) { if isCurrent { onViewportChange($0) } }
            .onChange(of: isCurrent) { if $0 { onViewportChange(cropViewport) } }
        }
        // Tap positions belong to the untransformed viewport, just like
        // Android detectTapGestures. Subtracting a global bounding-box origin
        // fails when RemoteReviewSurface rotates the whole canvas by 90/270°.
        .coordinateSpace(name: "photo-preview-viewport-\(file.id)")
        .onChange(of: panActive) { active in
            if !active { gestureStartOffset = scale > 1.01 ? offset : .zero }
        }
        .onChange(of: cropActive) { active in
            zoomAnimationTask?.cancel(); zoomAnimationTask = nil
            zoomAnimationActive = false; magnifying = false
            if active { cropReturnScale = scale; cropReturnOffset = offset }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)) {
                cropProgress = active ? 1 : 0
                scale = active ? 1 : cropReturnScale
                offset = active ? .zero : cropReturnOffset
            }
            gestureStartScale = scale; gestureStartOffset = offset
            onZoomedChange(scale > 1.01)
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
            if cropActive { cropReturnScale = 1; cropReturnOffset = .zero }
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
            // Keep the 300ms Android curve in the render transaction rather
            // than rebuilding the image/gesture hierarchy with a 60Hz Task.
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                highResolutionAlpha = 1
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
        guard pinchEnabled, zoomEnabled, isCurrent else { return }
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
            .updating($panActive) { _, active, _ in active = true }
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
        imageSize: CGSize?
    ) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .named("photo-preview-viewport-\(file.id)"))
            .exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: .named("photo-preview-viewport-\(file.id)")))
            .onEnded { value in
                guard isCurrent else { return }
                switch value {
                case .first(let doubleTap):
                    handleDoubleTap(
                        at: doubleTap.location,
                        viewportSize: viewportSize,
                        imageSize: imageSize
                    )
                case .second:
                    if interactive, (tapWhenZoomed || scale <= 1.01), !magnifying, !zoomAnimationActive { onTap() }
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

struct PhotoPreviewCropViewport: Equatable {
    let size: CGSize
    let scale: CGFloat
    let offset: CGSize
    let rotation: Double
    let infoBottom: CGFloat

    func visibleBounds(for preview: CropPreview) throws -> CropBounds {
        let placement = photoPreviewPlacement(imageSize: CGSize(width: preview.imageWidth, height: preview.imageHeight),
            viewportSize: size, rotationDegrees: rotation, infoBottom: infoBottom)
        let imageSize = CGSize(width: placement.size.width * scale, height: placement.size.height * scale)
        let frame = CGRect(x: placement.center.x + offset.width - imageSize.width / 2,
            y: placement.center.y + offset.height - imageSize.height / 2,
            width: imageSize.width, height: imageSize.height)
        return try preview.visibleBounds(viewport: CGRect(origin: .zero, size: size), imageFrame: frame)
    }
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
                           targetRotationDegrees: Double? = nil, cropTop: CGFloat = 0,
                           cropProgress: CGFloat = 0) -> PhotoPreviewPlacement {
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
                                    infoBottom: infoBottom, cropTop: cropTop + (orientedAspect > 1 ? 60 : 0),
                                    cropExtraBottom: 84, progress: cropProgress, cropTopAlignment: orientedAspect > 1 ? 0.5 : 1)
    let lift: CGFloat = orientedAspect < 1 ? min(12 * (1 - cropProgress), max(0, layout.centerY - height * fit * layout.scale / 2 - infoBottom)) : 0
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
struct PreviewRotationTransform: AnimatableModifier {
    var rotationDegrees: Double
    let targetRotationDegrees: Double
    let imageSize: CGSize?
    let viewportSize: CGSize
    var infoBottom: CGFloat? = nil
    var zoomScale: CGFloat = 1
    var cropTop: CGFloat = 0
    var cropProgress: CGFloat = 0

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(rotationDegrees, AnimatablePair(zoomScale, cropProgress)) }
        set { rotationDegrees = newValue.first; zoomScale = newValue.second.first; cropProgress = newValue.second.second }
    }

    func body(content: Content) -> some View {
        let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                              rotationDegrees: rotationDegrees, infoBottom: infoBottom,
                                              targetRotationDegrees: targetRotationDegrees, cropTop: cropTop, cropProgress: cropProgress)
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

@MainActor
final class PhotoPreviewPageFeedback: ObservableObject {
    @Published var offset: CGFloat = 0
}

/// Only lightweight information layers observe the per-frame pager offset.
/// The parent keeps the exact offset for gesture admission without observing it.
struct PhotoPreviewInformationFade: ViewModifier {
    @ObservedObject var feedback: PhotoPreviewPageFeedback
    let base: CGFloat
    func body(content: Content) -> some View {
        content.opacity(Double(base * previewPageInformationAlpha(feedback.offset)))
    }
}

private struct PreviewEffectsButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

@MainActor
final class PhotoPreviewGeometrySnapshot {
    var viewport: PhotoPreviewCropViewport?
}

@MainActor
final class PhotoPreviewQueueMotion: ObservableObject {
    @Published var offset: CGFloat = 0
}

struct PhotoPreviewQueueMotionTransform: ViewModifier {
    @ObservedObject var motion: PhotoPreviewQueueMotion
    func body(content: Content) -> some View {
        let lift = min(max(-motion.offset / 132, 0), 1)
        content.scaleEffect(1 - lift * 0.055).opacity(1 - lift * 0.07).offset(y: motion.offset)
    }
}

struct PhotoPreviewQueueAction: View {
    @ObservedObject private var controls: PhotoCropControlState
    let editing: Bool
    let confirming: Bool
    let enabled: Bool
    let action: () -> Void
    init(editor: PhotoCropEditingState, editing: Bool, confirming: Bool, enabled: Bool, action: @escaping () -> Void) {
        controls = editor.controls
        self.editing = editing
        self.confirming = confirming
        self.enabled = enabled
        self.action = action
    }
    var body: some View {
        let admitted = enabled && (!editing || (controls.snapshot.hasCrop && !confirming))
        Button(action: action) {
            ZStack {
                PreviewControlMark(icon: .add).opacity(editing ? 0 : 1)
                PreviewControlMark(icon: .check).opacity(editing ? 1 : 0)
            }
            .frame(width: 22, height: 22).opacity(admitted ? 1 : 0.35)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18), value: editing)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
        .accessibilityLabel(AppLocalized.resource(editing ? "crop_confirm" : "cd_transfer"))
        .disabled(!admitted)
    }
}
