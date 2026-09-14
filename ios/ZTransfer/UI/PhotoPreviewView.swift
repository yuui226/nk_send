import SwiftUI
import UIKit

enum LocalOriginalPreviewRoute: Equatable {
    case directBitmap
    case rawEmbeddedJPEG
    case cameraFHD
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
    let directory: URL?
    let organizeByDate: Bool
    @Binding var selectedFile: CameraFile?
    let onEnqueue: (CameraFile) -> Void
    @State private var index: Int
    @State private var rotationDegrees: Double = 0
    @AppStorage("preview_rotation_quarter_turns") private var rotationQuarterTurns = 0
    @State private var exif: PhotoExif?
    @State private var exifLoading = false
    // Android persists this switch in the transfer preference store, so it
    // survives leaving the preview and reopening the app.
    @AppStorage("preview_histogram_enabled") private var histogramVisible = false
    @State private var histogramBars: [CGFloat] = []
    @State private var queueDragOffset: CGFloat = 0
    @State private var queueFlightTask: Task<Void, Never>?
    @State private var queueFlightActive = false

    init(session: CameraSession, files: [CameraFile], selectedFile: Binding<CameraFile?>,
         directory: URL? = nil, organizeByDate: Bool = false,
         onEnqueue: @escaping (CameraFile) -> Void = { _ in }) {
        self.session = session; self.files = files; self.directory = directory
        self.organizeByDate = organizeByDate; _selectedFile = selectedFile; self.onEnqueue = onEnqueue
        let first = selectedFile.wrappedValue ?? files.first
        _index = State(initialValue: first.flatMap { files.firstIndex(of: $0) } ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(files.enumerated()), id: \.element.id) { itemIndex, file in
                    PreviewImage(
                        session: session,
                        file: file,
                        localOriginalURL: localOriginalURL(for: file),
                        rotationDegrees: rotationDegrees,
                        zoomEnabled: !file.fileExtension.lowercased().hasSuffix(".mov") &&
                            !file.fileExtension.lowercased().hasSuffix(".mp4"),
                    )
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
                              files.indices.contains(index) else { return }
                        let translation = value.translation
                        guard translation.height < 0,
                              -translation.height >= 96,
                              -translation.height >= abs(translation.width) * 1.15 else {
                            withAnimation(ZTransferMotion.standard) { queueDragOffset = 0 }
                            return
                        }
                        startQueueFlight(for: files[index])
                    }
            )
            VStack {
                HStack {
                    Button { selectedFile = nil } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                    Spacer()
                }
                Spacer()
                if let exif { PreviewExifBar(exif: exif).padding(.bottom, 78) }
            }
            .foregroundStyle(.white)
            if files.indices.contains(index) {
                VStack {
                    HStack {
                        Text(files[index].fileName)
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
                            .id(files[index].id)
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
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Spacer()
                    if files.indices.contains(index), !files[index].fileExtension.lowercased().contains(".mov"), !files[index].fileExtension.lowercased().contains(".mp4") {
                        Button { withAnimation(ZTransferMotion.standard) { histogramVisible.toggle() } } label: {
                            Image(systemName: "chart.bar.fill").frame(width: 44, height: 44)
                        }
                        .opacity(histogramVisible ? 1 : 0.82)
                    }
                    Button {
                        withAnimation(ZTransferMotion.standard) {
                            rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
                            rotationDegrees = -90 * Double(rotationQuarterTurns)
                        }
                    } label: { Image(systemName: "rotate.left").frame(width: 44, height: 44) }
                    Button { if files.indices.contains(index) { onEnqueue(files[index]) } } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
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
        }
        .onChange(of: index) { value in
            if files.indices.contains(value) {
                selectedFile = files[value]
                exif = nil
                exifLoading = false
            }
        }
        .task(id: files.indices.contains(index) ? files[index].id : 0) {
            guard files.indices.contains(index), !exifLoading else { return }
            histogramBars = []
            exifLoading = true
            let file = files[index]
            if let localURL = localOriginalURL(for: file) {
                if let data = try? Data(contentsOf: localURL) {
                    exif = PhotoExifParser.parse(data)
                }
                if let image = decodeLocalOriginalPreview(
                    at: localURL,
                    route: localOriginalPreviewRoute(for: file.fileExtension)
                ) {
                    histogramBars = luminanceHistogram(image)
                }
                exifLoading = false
                return
            }
            await session.setFHDActive(true)
            defer { Task { await session.setFHDActive(false) } }
            async let loadedExif = try? session.exif(file: files[index])
            async let loadedThumb = files[index].fileExtension == ".mov" || files[index].fileExtension == ".mp4"
                ? nil
                : (try? session.preview(handle: files[index].id))
            exif = await loadedExif
            if let data = await loadedThumb, let image = UIImage(data: data) { histogramBars = luminanceHistogram(image) }
            exifLoading = false
        }
    }

    /// Android checks the exact destination folder and file size before asking
    /// the camera for FHD. RAW and TIFF intentionally keep their camera/embedded
    /// preview routes; videos remain thumbnail-only.
    private func localOriginalURL(for file: CameraFile) -> URL? {
        guard let directory,
              localOriginalPreviewRoute(for: file.fileExtension) != .cameraFHD else { return nil }
        let destination = transferDestinationDirectory(
            root: directory,
            folderName: organizeByDate ? transferDateFolderName(file.captureDate) : nil
        )
        return existingTransferDestination(for: file, in: destination)
    }

    private func startQueueFlight(for file: CameraFile) {
        queueFlightActive = true
        withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.56)) {
            queueDragOffset = -max(240, UIScreen.main.bounds.height * 0.42)
        }
        queueFlightTask?.cancel()
        queueFlightTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 560_000_000)
            guard !Task.isCancelled else { return }
            onEnqueue(file)
            withAnimation(ZTransferMotion.standard) {
                queueDragOffset = 0
                queueFlightActive = false
            }
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

private struct PreviewImage: View {
    let session: CameraSession
    let file: CameraFile
    let localOriginalURL: URL?
    let rotationDegrees: Double
    let zoomEnabled: Bool
    @State private var thumbnail: UIImage?
    @State private var image: UIImage?
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
            if thumbnail == nil && image == nil { ProgressView().tint(.white) }
            if !zoomEnabled {
                Text(AppLocalized.resource("video_no_preview"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
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
            // Android shows the already cached/low-cost thumbnail first, then
            // replaces it with the FHD preview. Keep both requests in flight,
            // but publish the thumbnail as soon as it is available.
            if let localOriginalURL,
               let localImage = decodeLocalOriginalPreview(
                at: localOriginalURL,
                route: localOriginalPreviewRoute(for: file.fileExtension)
               ) {
                image = localImage
                highResolutionAlpha = 1
                return
            }
            if !zoomEnabled {
                if let data = try? await session.thumbnail(file: file), let thumb = UIImage(data: data) {
                    thumbnail = thumb
                }
                return
            }
            await session.setFHDActive(true)
            defer { Task { await session.setFHDActive(false) } }
            async let thumbnailData = try? await session.thumbnail(file: file)
            async let previewData = try? await session.preview(handle: file.id)
            if let data = await thumbnailData, let thumb = UIImage(data: data) {
                thumbnail = thumb
            }
            if let data = await previewData, let highResolution = UIImage(data: data) {
                image = highResolution
                if thumbnail == nil {
                    highResolutionAlpha = 1
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { highResolutionAlpha = 1 }
                }
            }
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
