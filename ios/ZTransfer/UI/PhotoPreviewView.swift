import SwiftUI
import UIKit

struct PhotoPreviewView: View {
    let session: CameraSession
    let files: [CameraFile]
    @Binding var selectedFile: CameraFile?
    let onEnqueue: (CameraFile) -> Void
    @State private var index: Int
    @State private var rotationDegrees: Double = 0
    @State private var exif: PhotoExif?
    @State private var exifLoading = false
    @State private var histogramVisible = false
    @State private var histogramBars: [CGFloat] = []

    init(session: CameraSession, files: [CameraFile], selectedFile: Binding<CameraFile?>, onEnqueue: @escaping (CameraFile) -> Void = { _ in }) {
        self.session = session; self.files = files; _selectedFile = selectedFile; self.onEnqueue = onEnqueue
        let first = selectedFile.wrappedValue ?? files.first
        _index = State(initialValue: first.flatMap { files.firstIndex(of: $0) } ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(files.enumerated()), id: \.element.id) { itemIndex, file in
                    PreviewImage(session: session, file: file, rotationDegrees: rotationDegrees)
                        .tag(itemIndex)
                        .padding(.horizontal, 12)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
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
                    Button { withAnimation(ZTransferMotion.standard) { rotationDegrees -= 90 } } label: { Image(systemName: "rotate.left").frame(width: 44, height: 44) }
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
            async let loadedExif = try? session.exif(file: files[index])
            async let loadedThumb = try? session.preview(handle: files[index].id)
            exif = await loadedExif
            if let data = await loadedThumb, let image = UIImage(data: data) { histogramBars = luminanceHistogram(image) }
            exifLoading = false
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
    let rotationDegrees: Double
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().tint(.white) }
        }
        .scaleEffect(scale).offset(offset).rotationEffect(.degrees(rotationDegrees))
        .gesture(MagnificationGesture().onChanged { scale = min(max($0, 1), 4) }.onEnded { _ in withAnimation(ZTransferMotion.standard) { scale = min(max(scale, 1), 4) } })
        .simultaneousGesture(DragGesture().onChanged { value in if scale > 1 { offset = value.translation } }.onEnded { _ in if scale <= 1 { offset = .zero } })
        .onTapGesture(count: 2) { withAnimation(ZTransferMotion.standard) { scale = scale > 1 ? 1 : 2 } }
        .task {
            guard image == nil else { return }
            if let data = try? await session.preview(handle: file.id), let image = UIImage(data: data) { self.image = image }
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
