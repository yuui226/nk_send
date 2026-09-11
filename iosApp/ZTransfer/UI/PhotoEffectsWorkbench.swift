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

    private let generateAndSave: @Sendable (IOSPhotoEffectAsset, IOSPhotoFilterSelection) async throws -> Bool

    init(
        session: PhotoEffectsBatchSession = PhotoEffectsBatchSession(),
        catalog: PhotoFilterCatalogStore = PhotoFilterCatalogStore(),
        generateAndSave: @escaping @Sendable (IOSPhotoEffectAsset, IOSPhotoFilterSelection) async throws -> Bool = { _, _ in false }
    ) {
        _session = StateObject(wrappedValue: session)
        _catalog = StateObject(wrappedValue: catalog)
        self.generateAndSave = generateAndSave
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
                    Button(session.generateButtonTitle) {
                        session.generateAndSave { asset in
                            guard let selection else { return false }
                            return try await generateAndSave(asset, selection)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isGenerating || selection == nil)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .sheet(isPresented: $pickerPresented) {
            PhotoEffectsPicker { values in
                session.replaceSelection(values)
                renderCurrent()
            }
        }
        .onChange(of: session.previewIndex) { _ in renderCurrent() }
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
