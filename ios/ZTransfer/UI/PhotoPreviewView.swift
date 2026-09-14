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
    let session: CameraSession
    let files: [CameraFile]
    let burstGroups: [BurstPhotoGroup]
    let queueTarget: CGRect?
    let directory: URL?
    let organizeByDate: Bool
    @Binding var selectedFile: CameraFile?
    /// Returns false when the Android preflight (directory/connection gate)
    /// rejects the task. The queue flight must not play without a real task.
    let onEnqueue: (CameraFile) -> Bool
    let onEnqueueBurst: ([CameraFile]) -> Bool
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

    init(session: CameraSession, files: [CameraFile], selectedFile: Binding<CameraFile?>,
         directory: URL? = nil, organizeByDate: Bool = false,
         queueTarget: CGRect? = nil,
         onEnqueue: @escaping (CameraFile) -> Bool = { _ in false },
         onEnqueueBurst: @escaping ([CameraFile]) -> Bool = { _ in false },
         onQueueFlightStarted: @escaping (Int) -> Void = { _ in },
         onQueueFlightFinished: @escaping (Int) -> Void = { _ in }) {
        self.session = session; self.files = files; self.directory = directory
        self.burstGroups = PhotoCatalogGrouping.bursts(in: files)
        self.queueTarget = queueTarget
        self.organizeByDate = organizeByDate; _selectedFile = selectedFile
        self.onEnqueue = onEnqueue; self.onEnqueueBurst = onEnqueueBurst
        self.onQueueFlightStarted = onQueueFlightStarted
        self.onQueueFlightFinished = onQueueFlightFinished
        let entries = collapsedPhotoPreviewEntries(files: files)
        let first = selectedFile.wrappedValue ?? files.first
        let initialIndex = first.flatMap { selected in
            entries.firstIndex { entry in
                switch entry {
                case .photo(let file, _): return file.id == selected.id
                case .burst(let group): return group.files.first?.id == selected.id
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
            Color.black.ignoresSafeArea()
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
                                         onDisplayImage: { image in
                                             displayedImages[file.id] = image
                                             guard histogramVisible, currentPhoto?.id == file.id else { return }
                                             histogramBars = image.map(luminanceHistogram) ?? []
                                         })
                        case .burst(let group):
                            BurstCollectionPreview(session: session, group: group) {
                                expandBurst(group)
                            }
                        }
                    }
                        .tag(itemIndex)
                        .padding(.horizontal, 12)
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
                        guard translation.height < 0,
                              -translation.height >= abs(translation.width) * 1.15 else {
                            return
                        }
                        queueDragOffset = max(-180, translation.height)
                    }
                    .onEnded { value in
                        guard !queueFlightActive,
                              previewEntries.indices.contains(index) else { return }
                        let translation = value.translation
                        guard translation.height < 0,
                              -translation.height >= 96,
                              -translation.height >= abs(translation.width) * 1.15 else {
                            withAnimation(ZTransferMotion.standard) { queueDragOffset = 0 }
                            return
                        }
                        switch previewEntries[index] {
                        case .photo(let file, _): startQueueFlight(for: file)
                        case .burst(let group): startQueueFlight(for: group.files[0])
                        }
                    }
            )
            if queueFlightActive, previewEntries.indices.contains(index) {
                GeometryReader { proxy in
                    PhotoPreviewQueueFlightView(
                        progress: queueFlightProgress,
                        image: queueFlightImage,
                        images: queueFlightImages,
                        from: CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.46),
                        target: CGPoint(
                            x: (queueTarget?.midX ?? (proxy.size.width - 74)) - proxy.frame(in: .global).minX,
                            y: (queueTarget?.midY ?? (proxy.safeAreaInsets.top + 18)) - proxy.frame(in: .global).minY
                        ),
                        size: CGSize(width: proxy.size.width * 0.72, height: proxy.size.height * 0.52),
                        stackCount: queueFlightCount
                    )
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button { selectedFile = nil } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                    Spacer()
                }
                Spacer()
                if let exif { PreviewExifBar(exif: exif).padding(.bottom, 78) }
            }
            .foregroundStyle(.white)
            if previewEntries.indices.contains(index), let file = previewEntries[index].file {
                VStack {
                    HStack {
                        Text(file.fileName)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            // Android PreviewInfoText scales the filename to
                            // its measured width and clips only as a last
                            // resort; SwiftUI's default ellipsis changes the
                            // visible text, so prefer the same shrink-first
                            // behavior here.
                            .minimumScaleFactor(0.5)
                            .allowsTightening(true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(file.id)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        Spacer(minLength: 44)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .animation(ZTransferMotion.standard, value: index)
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.88))
                .transition(.opacity)
            }
            if previewEntries.indices.contains(index),
               let burstID = previewEntries[index].burstID,
               let group = burstGroups.first(where: { $0.id == burstID }) {
                Button {
                    withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)) {
                        previewEntries = collapsePhotoPreviewBurst(previewEntries, burstID: group.id)
                        _ = expandedBurstIDs.remove(group.id)
                        index = previewEntries.firstIndex { entry in
                            if case .burst(let value) = entry { return value.id == group.id }
                            return false
                        } ?? index
                    }
                } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .font(.system(size: 18, weight: .semibold))
                .background(.black.opacity(0.28), in: Capsule())
                .foregroundStyle(.white)
                .padding(.leading, 16)
                .padding(.top, 54)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Spacer()
                    if let file = currentPhoto, !file.fileExtension.lowercased().contains(".mov"), !file.fileExtension.lowercased().contains(".mp4") {
                        Button { withAnimation(ZTransferMotion.standard) { histogramVisible.toggle() } } label: {
                            Image(systemName: "chart.bar.fill").frame(width: 44, height: 44)
                        }
                        .opacity(histogramVisible ? 1 : 0.82)
                    }
                    if currentPhoto != nil {
                        Button {
                            withAnimation(ZTransferMotion.standard) {
                                rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
                                rotationDegrees = -90 * Double(rotationQuarterTurns)
                            }
                        } label: { Image(systemName: "rotate.left").frame(width: 44, height: 44) }
                    }
                    Button {
                        guard previewEntries.indices.contains(index) else { return }
                        switch previewEntries[index] {
                        case .photo(let file, _): startQueueFlight(for: file)
                        case .burst(let group): startQueueFlight(for: group.files[0])
                        }
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                }
                .font(.system(size: 18, weight: .semibold))
                .background(.black.opacity(0.28), in: Capsule())
                .padding(.trailing, 16)
                .padding(.bottom, 22)
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
                .padding(.bottom, 94)
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
            // PreviewImage owns the single thumbnail/FHD pipeline. EXIF is
            // independent; requesting another preview here would duplicate
            // the camera read and race the Android-ordered loader.
            exif = try? await session.exif(file: file)
            exifFinished.insert(file.id)
            exifLoading = false
        }
    }

    private var currentPhoto: CameraFile? {
        guard previewEntries.indices.contains(index) else { return nil }
        return previewEntries[index].file
    }

    private func expandBurst(_ group: BurstPhotoGroup) {
        guard let collectionIndex = previewEntries.firstIndex(where: { entry in
            if case .burst(let value) = entry { return value.id == group.id }
            return false
        }) else { return }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)) {
            previewEntries = expandPhotoPreviewBurst(previewEntries, at: collectionIndex)
            expandedBurstIDs.insert(group.id)
            index = collectionIndex + 1
            selectedFile = group.files.first
        }
    }

    private func startQueueFlight(for file: CameraFile) {
        let burst = burstGroups.first(where: { $0.files.first?.id == file.id })
        guard burst == nil ? onEnqueue(file) : onEnqueueBurst(burst!.files) else { return }
        let flightCount = burst?.files.count ?? 1
        onQueueFlightStarted(flightCount)
        queueFlightCount = flightCount
        queueFlightActive = true
        queueFlightProgress = 0
        queueFlightImage = nil
        queueFlightImages = []
        withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.56)) {
            queueDragOffset = -max(240, UIScreen.main.bounds.height * 0.42)
            queueFlightProgress = 1
        }
        queueFlightTask?.cancel()
        queueFlightTask = Task { @MainActor in
            let burstFiles = burst?.files.prefix(3).map { $0 } ?? [file]
            var cachedImages: [UIImage] = []
            var cachedLayers: [UIImage?] = []
            for candidate in burstFiles {
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
            withAnimation(ZTransferMotion.standard) {
                queueDragOffset = 0
                queueFlightActive = false
            }
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

/// Android's collapsed burst page: a compact stack of up to three cached
/// thumbnails with a count badge and an explicit expand affordance.  It never
/// starts a camera request solely to draw the stack; uncached members remain
/// placeholders until their normal preview page is selected.
private struct BurstCollectionPreview: View {
    let session: CameraSession
    let group: BurstPhotoGroup
    let onExpand: () -> Void

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
                Text("\(group.files.count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.62), in: Capsule())
                    .frame(width: side, height: side, alignment: .topLeading)
                    .padding(8)
                Button(action: onExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.white)
                .background(.black.opacity(0.32), in: Circle())
                .frame(width: side, height: side, alignment: .bottomTrailing)
                .padding(8)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let onDisplayImage: (UIImage?) -> Void
    @State private var thumbnail: UIImage?
    @State private var image: UIImage?
    @State private var remoteThumbnailUnavailable = false
    @State private var highResolutionAlpha: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

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
            scale = min(max(value, 1), 4)
        }.onEnded { _ in
            guard zoomEnabled else { return }
            withAnimation(ZTransferMotion.standard) { scale = min(max(scale, 1), 4) }
        })
        .simultaneousGesture(DragGesture().onChanged { value in
            if zoomEnabled, scale > 1 { offset = value.translation }
        }.onEnded { _ in if !zoomEnabled || scale <= 1 { offset = .zero } })
        .onTapGesture(count: 2) {
            guard zoomEnabled else { return }
            withAnimation(ZTransferMotion.standard) { scale = scale > 1 ? 1 : 2 }
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
                return
            }
            if !zoomEnabled {
                onFHDUnavailable(true)
                return
            }
            await session.setFHDActive(true)
            defer { Task { await session.setFHDActive(false) } }
            async let previewData = try? await session.preview(handle: file.id)
            if let data = await previewData, let highResolution = UIImage(data: data) {
                image = highResolution
                onFHDUnavailable(false)
                onDisplayImage(highResolution)
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
