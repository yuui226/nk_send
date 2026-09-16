import SwiftUI
import UIKit

enum LocalOriginalPreviewRoute: Equatable {
    case directBitmap
    case rawEmbeddedJPEG
    case cameraFHD
}

private let videoFourGiB = UInt64(4) * 1024 * 1024 * 1024

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
    if let raw = file.captureDate, raw.count >= 8,
       let year = Int(raw.prefix(4)), let month = Int(raw.dropFirst(4).prefix(2)),
       let day = Int(raw.dropFirst(6).prefix(2)),
       (1...12).contains(month), (1...31).contains(day) {
        var date = String(format: "%04d-%02d-%02d", year, month, day)
        if raw.count >= 15, raw.dropFirst(8).first == "T",
           let hour = Int(raw.dropFirst(9).prefix(2)),
           let minute = Int(raw.dropFirst(11).prefix(2)),
           let second = Int(raw.dropFirst(13).prefix(2)),
           (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) {
            date += String(format: " %02d:%02d:%02d", hour, minute, second)
        }
        values.append(date)
    }
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
    @State private var fhdUnavailable: Set<UInt32> = []
    @State private var exifFinished: Set<UInt32> = []
    @State private var queueDragOffset: CGFloat = 0
    @State private var currentZoomed = false
    @State private var queueFlightTask: Task<Void, Never>?
    @State private var queueFlightActive = false
    @State private var queueFlightProgress: CGFloat = 0
    @State private var queueFlightImage: UIImage?
    @State private var queueFlightImages: [UIImage?] = []
    @State private var queueFlightCount = 0
    @State private var expandedBurstIDs: Set<String> = []
    /// Android snapshots already-exported originals when the preview overlay
    /// opens; a transfer completing underneath must not replace the source of
    /// the current page halfway through its load.
    @State private var localOriginalURLs: [UInt32: URL]

    init(session: CameraSession, queueModel: TransferQueueViewModel, files: [CameraFile],
         burstIDByFile: [UInt32: String] = [:], transferredFileIDs: Set<UInt32> = [],
         selectedFile: Binding<CameraFile?>,
         directory: URL? = nil, organizeByDate: Bool = false,
         queueTarget: CGRect? = nil,
         initialExpandedBurstIDs: Set<String> = [],
         collapseBursts: Bool = true,
         onBurstChanged: @escaping (String, Bool) -> Void = { _, _ in },
         onEnqueue: @escaping (CameraFile) -> Bool = { _ in false },
         onEnqueueBurst: @escaping ([CameraFile]) -> Bool = { _ in false },
         onQueueFlightStarted: @escaping (Int) -> Void = { _ in },
         onQueueFlightFinished: @escaping (Int) -> Void = { _ in }) {
        self.queueModel = queueModel
        self.session = session; self.files = files; self.directory = directory
        self.burstGroups = PhotoCatalogGrouping.bursts(in: files)
        self.burstIDByFile = burstIDByFile
        self.transferredFileIDs = transferredFileIDs
        self.queueTarget = queueTarget
        self.organizeByDate = organizeByDate; _selectedFile = selectedFile
        self.onEnqueue = onEnqueue; self.onEnqueueBurst = onEnqueueBurst
        self.onQueueFlightStarted = onQueueFlightStarted
        self.onQueueFlightFinished = onQueueFlightFinished
        self.onBurstChanged = onBurstChanged
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
        _previewEntries = State(initialValue: entries)
        _index = State(initialValue: initialIndex)
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
            Color.black.opacity(0.74).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(previewEntries.enumerated()), id: \.element.id) { itemIndex, entry in
                    Group {
                        switch entry {
                        case .photo(let file, _):
                            PreviewImage(session: session, file: file,
                                         localOriginalURL: localOriginalURLs[file.id],
                                         rotationDegrees: rotationDegrees,
                                         zoomEnabled: !file.fileExtension.lowercased().hasSuffix(".mov") &&
                                            !file.fileExtension.lowercased().hasSuffix(".mp4"),
                                         allowRemoteThumbnailFallback: fhdUnavailable.contains(file.id) &&
                                            exifFinished.contains(file.id),
                                         onFHDUnavailable: { unavailable in
                                             if unavailable { fhdUnavailable.insert(file.id) }
                                             else { fhdUnavailable.remove(file.id) }
                                         },
                                         onRemoteExif: { metadata in
                                             guard currentPhoto?.id == file.id else { return }
                                             exif = metadata
                                             exifFinished.insert(file.id)
                                         },
                                         onDisplayImage: { image in
                                             displayedImages[file.id] = image
                                             guard histogramVisible, currentPhoto?.id == file.id else { return }
                                             histogramBars = image.map(luminanceHistogram) ?? []
                                         }, onHighResolutionLoaded: {
                                             if currentPhoto?.id == file.id { ZTransferHaptics.shared.tick() }
                                         }, onTap: { selectedFile = nil },
                                         onZoomedChange: { zoomed in if index == itemIndex { currentZoomed = zoomed } },
                                         isCurrent: index == itemIndex)
                        case .burst(let group):
                            BurstCollectionPreview(session: session, group: group, onTap: { selectedFile = nil })
                        }
                    }
                        .tag(itemIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: queueDragOffset)
            .allowsHitTesting(!queueFlightActive)
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
        .onAppear {
            rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
            rotationDegrees = -90 * Double(rotationQuarterTurns)
        }
        .onDisappear {
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
            }
        }
        .onChange(of: histogramVisible) { visible in
            guard visible, let file = currentPhoto,
                  let image = displayedImages[file.id] else { return }
            histogramBars = luminanceHistogram(image)
        }
        .task(id: previewEntries.indices.contains(index) ? previewEntries[index].id : "none") {
            guard let file = currentPhoto, !exifLoading else { return }
            histogramBars = []
            exifLoading = true
            if let localURL = localOriginalURLs[file.id] {
                if let data = try? Data(contentsOf: localURL) {
                    exif = PhotoExifParser.parse(data)
                }
                exifFinished.insert(file.id)
                exifLoading = false
                return
            }
            // Remote EXIF is loaded by PreviewImage in the same interactive
            // reservation as FHD. Local originals remain on this path above.
            guard localOriginalURLs[file.id] != nil else {
                exifLoading = false
                return
            }
            exifLoading = false
        }
    }

    private var currentPhoto: CameraFile? {
        guard previewEntries.indices.contains(index) else { return nil }
        return previewEntries[index].file
    }

    private func isVideo(_ file: CameraFile) -> Bool {
        [".mov", ".mp4"].contains(file.fileExtension.lowercased())
    }

    private func transferredOriginal(_ file: CameraFile) -> Bool {
        transferredFileIDs.contains(file.id) || localOriginalURLs[file.id] != nil ||
            queueModel.task(for: file.id)?.status == .completed
    }

    private func collapseCurrentBurst() {
        guard let collectionIndex = photoPreviewCollectionIndex(previewEntries, memberIndex: index),
              case let .burst(group) = previewEntries[collectionIndex] else { return }
        ZTransferHaptics.shared.tick()
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) {
            previewEntries = collapsePhotoPreviewBurst(previewEntries, burstID: group.id)
            expandedBurstIDs.remove(group.id)
            onBurstChanged(group.id, false)
            index = collectionIndex
            selectedFile = group.files.first
        }
    }

    private func expandBurst(_ group: BurstPhotoGroup) {
        guard let collectionIndex = previewEntries.firstIndex(where: { entry in
            if case .burst(let value) = entry { return value.id == group.id }
            return false
        }) else { return }
        ZTransferHaptics.shared.tick()
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)) {
            if !expandedBurstIDs.contains(group.id) { previewEntries = expandPhotoPreviewBurst(previewEntries, at: collectionIndex) }
            expandedBurstIDs.insert(group.id)
            onBurstChanged(group.id, true)
            index = collectionIndex + 1
            selectedFile = group.files.first
        }
    }

    private func startQueueFlight(for file: CameraFile, burstFiles: [CameraFile]? = nil) {
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
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * 0.72, proxy.size.height * 0.46)
            ZStack {
                ForEach(Array(group.files.prefix(3).reversed().enumerated()), id: \.element.id) { index, file in
                    CachedBurstThumbnail(session: session, file: file)
                        .frame(width: side * 0.86, height: side * 0.86)
                        .rotationEffect(.degrees(index == 0 ? -6 : index == 1 ? 5 : 0))
                        .offset(x: index == 0 ? -12 : index == 1 ? 12 : 0,
                                y: index == 2 ? 2 : 5)
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
    let localOriginalURL: URL?
    let rotationDegrees: Double
    let zoomEnabled: Bool
    let allowRemoteThumbnailFallback: Bool
    let onFHDUnavailable: (Bool) -> Void
    let onRemoteExif: (PhotoExif?) -> Void
    let onDisplayImage: (UIImage?) -> Void
    let onHighResolutionLoaded: () -> Void
    let onTap: () -> Void
    let onZoomedChange: (Bool) -> Void
    let isCurrent: Bool
    @State private var thumbnail: UIImage?
    @State private var image: UIImage?
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
                             ? (image == nil ? 1 : 1 - highResolutionAlpha)
                             : 0.56)
            }
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .opacity(thumbnail == nil ? 1 : highResolutionAlpha)
            }
            if thumbnail == nil && image == nil {
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
        .task(id: file.id) {
            thumbnail = nil
            image = nil
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
            try? await Task.sleep(nanoseconds: 340_000_000)
            guard !Task.isCancelled else { return }
            if let localOriginalURL,
               let localImage = decodeLocalOriginalPreview(
                at: localOriginalURL,
                route: localOriginalPreviewRoute(for: file.fileExtension)
               ) {
                image = localImage
                highResolutionAlpha = 1
                onDisplayImage(localImage)
                onHighResolutionLoaded()
                return
            }
            if !zoomEnabled {
                onFHDUnavailable(true)
                return
            }
            await session.setFHDActive(true)
            defer { Task { await session.setFHDActive(false) } }
            let (previewData, metadata) = await session.previewAndExif(file: file)
            guard !Task.isCancelled else { return }
            onRemoteExif(metadata)
            if let data = previewData, let highResolution = UIImage(data: data) {
                image = highResolution
                onFHDUnavailable(false)
                onDisplayImage(highResolution)
                onHighResolutionLoaded()
                if thumbnail == nil {
                    highResolutionAlpha = 1
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { highResolutionAlpha = 1 }
                }
            } else if !Task.isCancelled {
                onFHDUnavailable(true)
            }
        }
        .task(id: allowRemoteThumbnailFallback) {
            guard allowRemoteThumbnailFallback, thumbnail == nil, image == nil else { return }
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
