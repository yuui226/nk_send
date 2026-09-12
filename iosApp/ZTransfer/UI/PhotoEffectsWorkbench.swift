import SwiftUI
import UIKit

/// Reusable iOS workbench shell. CameraWorkspace can present this view from either the settings
/// effect card or the phone-photo workbench without duplicating picker, wheel or progress logic.
@MainActor
struct PhotoEffectsWorkbench: View {
    @StateObject private var session: PhotoEffectsBatchSession
    @StateObject private var catalog: PhotoFilterCatalogStore
    @StateObject private var previews = PhotoEffectsPreviewStore()
    @State private var selection: IOSPhotoFilterSelection?
    @State private var pickerPresented = false
    @State private var intensity = 80.0
    @State private var artifactFiles: [PhotoEffectsRenderedFile] = []
    @State private var filesExportPresented = false
    @State private var sharePresented = false
    @State private var exportStatus = ""

    private let customGenerateAndSave: (@Sendable (IOSPhotoEffectAsset, IOSPhotoFilterSelection) async throws -> Bool)?
    private var artifactSink: PhotoEffectsArtifactSink { session.artifacts }

    init(
        session: PhotoEffectsBatchSession = PhotoEffectsBatchSession(),
        catalog: PhotoFilterCatalogStore = PhotoFilterCatalogStore(),
        generateAndSave: (@Sendable (IOSPhotoEffectAsset, IOSPhotoFilterSelection) async throws -> Bool)? = nil
    ) {
        _session = StateObject(wrappedValue: session)
        _catalog = StateObject(wrappedValue: catalog)
        self.customGenerateAndSave = generateAndSave
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("照片效果")
                    .font(.title3.weight(.semibold))
                Spacer()
                PhotoEffectsHelpButton()
                if !session.assets.isEmpty {
                    Button("重新选择") { pickerPresented = true }
                        .buttonStyle(.bordered)
                        .disabled(session.isGenerating)
                }
            }
            .padding(.horizontal)

            if session.assets.isEmpty {
                Button { pickerPresented = true } label: {
                    Label("选择照片", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            } else {
                PhotoEffectsPreviewPager(session: session) { asset in
                    Group {
                        if let image = previews.image(for: asset) {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        if previews.renderingID == asset.id { ProgressView() }
                    }
                    .padding(.horizontal)
                }
                .frame(minHeight: 240, maxHeight: 480)

                HStack(spacing: 10) {
                    PhotoFilterWheelLauncher(store: catalog, onTap: cycleFilter, onSelection: choose) {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.filters")
                            Text(catalog.selectedEntry?.name ?? "选择滤镜").lineLimit(1)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).frame(height: 42)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    Slider(value: $intensity, in: 2...100, step: 2) { editing in
                        if !editing { applyIntensity() }
                    }
                    .disabled(selection == nil)
                    Text("\(Int(intensity))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Text("已选 \(session.selectedCount) 张")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session.canRetryFailed {
                        Button("重试失败 \(session.failedAssets.count) 张") {
                            session.retryFailed()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(session.generateButtonTitle, action: startGeneration)
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isGenerating || selection == nil)
                }
                .padding(.horizontal)

                if !session.completedAssets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Label("已保存", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            ForEach(session.completedAssets) { asset in
                                Text(asset.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .frame(height: 28)
                                    .background(Color.green.opacity(0.10), in: Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                if !artifactFiles.isEmpty {
                    HStack(spacing: 10) {
                        Button("导出到 Files") { filesExportPresented = true }
                        Button("分享") { sharePresented = true }
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.isGenerating)
                }
            }
            if !exportStatus.isEmpty {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .sheet(isPresented: $pickerPresented) {
            PhotoEffectsPicker { result in
                pickerPresented = false
                guard case let .selected(values, failedCount) = result else { return }
                guard !values.isEmpty else {
                    exportStatus = "未能读取所选照片，请重新选择。"
                    return
                }
                guard session.replaceSelection(values) else { return }
                artifactSink.clear()
                artifactFiles = []
                exportStatus = failedCount == 0 ? "" : "\(failedCount) 张照片未能读取，其余已载入。"
                previews.clear()
                renderCurrent()
            }
        }
        .onChange(of: session.previewIndex) { _ in renderCurrent() }
        .onChange(of: session.status) { _ in
            let byID = Dictionary(uniqueKeysWithValues: artifactSink.snapshot().map { ($0.assetID, $0) })
            artifactFiles = session.assets.compactMap { byID[$0.id] }
        }
        .sheet(isPresented: $filesExportPresented) {
            PhotoEffectsDocumentExporter(files: artifactFiles) { urls in
                filesExportPresented = false
                exportStatus = urls.map { "已接收 \($0.count) 个文件" } ?? "已取消导出"
            }
        }
        .sheet(isPresented: $sharePresented) {
            PhotoEffectsShareSheet(files: artifactFiles) {
                sharePresented = false
                exportStatus = "分享面板已关闭"
            }
        }
    }

    private func startGeneration() {
        guard !session.isGenerating, let selection else { return }
        artifactSink.clear()
        artifactFiles = []
        exportStatus = ""
        let publisher = session.photosPublisher
        session.generateAndSave { [selection, customGenerateAndSave, artifactSink, publisher] asset in
            if let customGenerateAndSave {
                return try await customGenerateAndSave(asset, selection)
            }
            // Two renderers share one serialized publisher, including the permission request.
            let exportService = PhotoEffectsExportService(publisher: publisher)
            let artifact = try await exportService.render(asset, selection: selection)
            try await exportService.saveToPhotos(artifact)
            artifactSink.replace(artifact)
            return true
        }
    }

    private func choose(_ value: IOSPhotoFilterSelection) {
        selection = value
        intensity = Double(value.intensityPercent)
        renderCurrent()
    }

    private func cycleFilter() {
        guard let current = catalog.selectedEntry,
              let index = catalog.visibleEntries.firstIndex(of: current),
              !catalog.visibleEntries.isEmpty else { return }
        choose(catalog.selection(for: catalog.visibleEntries[(index + 1) % catalog.visibleEntries.count]))
    }

    private func applyIntensity() {
        guard let entry = catalog.selectedEntry else { return }
        catalog.setIntensity(Int(intensity), for: entry)
        choose(catalog.selection(for: entry))
    }

    private func renderCurrent() {
        guard let asset = session.currentAsset, let selection else { return }
        previews.render(asset, selection: selection)
    }
}

private extension PhotoFilterCatalogStore {
    var selectedEntry: IOSPhotoFilterEntry? { entries.first { $0.catalogKey == selectedKey } }
}
