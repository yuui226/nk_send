import PhotosUI
import SwiftUI

/// Android LocalPhotoEffectsPage: fixed 4:3 pager, batch action, inline editors.
/// The picked list is the batch selection; there is no second selection grid.
struct LocalPhotoEffectsView: View {
    let onNavigateUp: () -> Void
    @StateObject private var effectsStore = PhotoEffectsStore(scope: .localPhotos)
    @StateObject private var batch = LocalPhotoBatchViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var watermarkPickerItems: [PhotosPickerItem] = []
    @State private var previewPage = 0
    @State private var showingPicker = false
    @State private var showingHelp = false
    @State private var showingWatermarkPicker = false
    @State private var filterChooser = PhotoFilterChooserState()
    @State private var effectsHint: PhotoEffectsHint?
    @State private var scrollOffset: CGFloat = 0
    @FocusState private var watermarkTextFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                toolbar
                preview.padding(.top, 14)
                batchButton.padding(.top, 10)
                batchFailureView
                PhotoEffectsControls(draft: effectsBinding,
                                       showingWatermarkPicker: $showingWatermarkPicker,
                                       textFieldFocused: $watermarkTextFocused,
                                       showLocationFields: false,
                                       filterChooser: $filterChooser,
                                       onFavoriteImageMissing: { effectsHint = .init(resource: "photo_effect_favorite_image_missing") })
                .padding(.top, 10).padding(.bottom, 18)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
            .background(WorkbenchScrollTracker())
        }
        .coordinateSpace(name: "workbenchScroll")
        .onPreferenceChange(WorkbenchScrollOffsetKey.self) { scrollOffset = $0 }
        // The Android pager takes over when the workbench is at its top edge.
        // Keeping this simultaneous avoids stealing vertical scrolling inside
        // the editor once the user has moved down the page.
        .simultaneousGesture(DragGesture(minimumDistance: 18).onEnded { value in
            // Wheel drags are vertical too, but short option controls no
            // longer install a competing drag recognizer. Let a downward
            // gesture from any part of the top-scrolled workbench reach the
            // page pager; long option wheels still take precedence themselves.
            // A horizontal drag belongs to the photo pager. Explicitly
            // checking the dominant axis is important here because this
            // gesture is attached to the enclosing vertical ScrollView and
            // otherwise competes with TabView's page recognizer.
            guard abs(value.translation.height) > abs(value.translation.width),
                  !watermarkTextFocused,
                  scrollOffset >= -2,
                  value.translation.height > 70 else { return }
            onNavigateUp()
        })
        .background(ZTransferColors.background.ignoresSafeArea())
        .overlay {
            if filterChooser.isPresented {
                PhotoFilterChooserOverlay(draft: effectsBinding, state: $filterChooser)
            }
        }
        .photoEffectsHint($effectsHint, duration: 2)
        .photosPicker(isPresented: $showingPicker, selection: $pickerItems,
                      matching: .images, preferredItemEncoding: .current)
        .photosPicker(isPresented: $showingWatermarkPicker, selection: $watermarkPickerItems,
                      maxSelectionCount: 1, matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty, !batch.state.generating else { return }
            batch.select(items)
            previewPage = 0
        }
        .onChange(of: watermarkPickerItems) { items in
            guard let item = items.last else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let hash = effectsStore.importWatermarkImage(image) else {
                    effectsHint = .init(resource: "photo_frame_image_import_failed")
                    await MainActor.run { watermarkPickerItems = [] }
                    return
                }
                var watermark = effectsStore.settings.watermark
                watermark.content = .image
                watermark.imageHash = hash
                var updated = effectsStore.settings
                updated.watermark = watermark
                if updated.photoFrameBorderEnabled,
                   let index = updated.favoriteFrameEffects.firstIndex(where: { $0.preset == updated.photoFramePreset }) {
                    updated.favoriteFrameEffects[index].watermark = watermark
                }
                effectsStore.update(updated)
                await MainActor.run { watermarkPickerItems = [] }
            }
        }
        .alert(AppLocalized.resource("photo_effects_info_title"), isPresented: $showingHelp) {
            Button(AppLocalized.resource("cd_close"), role: .cancel) {}
        } message: {
            Text([
                AppLocalized.resource("local_photo_effects_info_description"),
                AppLocalized.resource("local_photo_effects_gesture_hint"),
                AppLocalized.resource("local_photo_effects_exif_hint"),
                AppLocalized.resource("local_photo_same_folder_hint")
            ].joined(separator: "\n"))
        }
    }

    private var batchHasFailure: Bool {
        batch.state.phase == .partial || batch.state.phase == .failed
    }

    private var batchFailureText: String {
        let failed = batch.state.progress.failed
        return AppLocalized.formattedResource("local_photo_batch_failure_detail", ["%1$d": "\(failed)"])
    }

    @ViewBuilder private var batchFailureView: some View {
        if batchHasFailure {
            Text(batchFailureText)
                .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }

    private var effectsBinding: Binding<PhotoEffectsSettings> {
        Binding(get: { effectsStore.settings }, set: { effectsStore.update($0) })
    }

    private var previewSettings: PhotoEffectsSettings {
        var value = effectsStore.settings
        value.metadata = value.metadataByPreset[value.photoFramePreset.rawValue] ?? value.metadata
        return value
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onNavigateUp) {
                Image(systemName: "chevron.up").font(.system(size: 19, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(WorkbenchGlassButtonStyle())
            Text(AppLocalized.resource("local_photo_effects_entry")).font(.system(size: 16, weight: .bold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !batch.state.photos.isEmpty {
                Button { showingPicker = true } label: {
                    Text(AppLocalized.resource("local_photo_replace")).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 38)
                }
                .buttonStyle(WorkbenchGlassButtonStyle()).disabled(batch.state.generating)
            }
            Button { showingHelp = true } label: {
                Image(systemName: "lightbulb.fill").foregroundStyle(ZTransferColors.accentOrange)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(WorkbenchGlassButtonStyle()).accessibilityLabel(AppLocalized.resource("photo_effects_info_title"))
        }
        .foregroundStyle(ZTransferColors.primaryText)
    }

    private var preview: some View {
        Group {
            if batch.state.photos.isEmpty {
                Button { showingPicker = true } label: {
                    VStack(spacing: 6) {
                        Text(AppLocalized.resource("local_photo_choose_short")).font(.system(size: 14, weight: .medium)).foregroundStyle(ZTransferColors.accentBlue)
                        Text(AppLocalized.resource("local_photo_multi_select")).font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ZTransferColors.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZTransferColors.secondaryText.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else {
                TabView(selection: $previewPage) {
                    ForEach(batch.state.photos.indices, id: \.self) { index in
                        Group {
                            // Only the visible page and immediate neighbours
                            // retain bounded 1280-pixel previews.
                            if abs(index - previewPage) <= 1 {
                                LocalEffectPreview(item: batch.state.photos[index], settings: previewSettings)
                            } else { Color.clear }
                        }.tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Keep the whole 4:3 preview as the pager's hit region. The
                // child preview also has a long-press comparison gesture, so
                // the pager must be allowed to win ordinary horizontal drags.
                .contentShape(Rectangle())
                .id(batch.state.photos)
            }
        }
        .aspectRatio(4.0 / 3, contentMode: .fit)
    }

    private var batchButton: some View {
        Button {
            if batch.state.photos.isEmpty { showingPicker = true }
            else { batch.generate(settings: previewSettings) }
        } label: {
            LocalPhotoBatchLabel(state: batch.state)
                .frame(maxWidth: .infinity).frame(height: 50).clipped()
        }
        .buttonStyle(WorkbenchGlassButtonStyle())
        .disabled(batch.state.phase != .ready || (!batch.state.photos.isEmpty && !effectsStore.settings.hasEffect))
    }
}

private struct WorkbenchScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct WorkbenchScrollTracker: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WorkbenchScrollOffsetKey.self,
                                   value: proxy.frame(in: .named("workbenchScroll")).minY)
        }
    }
}

private struct LocalPhotoBatchLabel: View {
    let state: LocalPhotoBatchState<PhotosPickerItem>
    @State private var previousPhase: LocalPhotoBatchPhase = .ready

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                if state.phase == .generating {
                    HStack(spacing: 0) {
                        Text(AppLocalized.resource("local_photo_batch_generating") + " ")
                        Text("\(state.progress.completed)").fontWeight(.bold).monospacedDigit()
                            .id(state.progress.completed)
                            .transition(.asymmetric(
                                insertion: .offset(y: -8).combined(with: .opacity).animation(.easeOut(duration: 0.16)),
                                removal: .offset(y: 8).combined(with: .opacity).animation(.easeOut(duration: 0.12))))
                        Text("/\(state.progress.total)").fontWeight(.bold).monospacedDigit()
                    }
                } else { Text(text) }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(ZTransferColors.primaryText)
            .id(state.phase)
            .transition(ZTransferMotion.buttonStateTransition(forward: state.phase.rawValue >= previousPhase.rawValue))
        }
        .animation(.easeInOut(duration: 0.22), value: state.phase)
        .animation(.easeOut(duration: 0.16), value: state.progress.completed)
        .onChange(of: state.phase) { previousPhase = $0 }
    }

    private var text: String {
        switch state.phase {
        case .complete:
            AppLocalized.formattedResource("local_photo_batch_saved", ["%1$d": "\(state.progress.saved)"])
        case .partial:
            AppLocalized.formattedResource("local_photo_batch_partial", [
                "%1$d": "\(state.progress.saved)", "%2$d": "\(state.progress.total)"
            ])
        case .failed:
            AppLocalized.resource("local_photo_batch_failed")
        default:
            state.photos.isEmpty
                ? AppLocalized.resource("local_photo_choose_short")
                : AppLocalized.formattedResource("local_photo_batch_generate", ["%1$d": "\(state.photos.count)"])
        }
    }
}

private struct LocalEffectPreview: View {
    let item: PhotosPickerItem
    let settings: PhotoEffectsSettings
    @State private var source: UIImage?
    @State private var metadata: PhotoFrameMetadata?
    @State private var images: LocalPhotoPreviewImages?
    @State private var filteredSource: UIImage?
    @State private var filteredSourceKey: PhotoFilterSelection?
    @State private var prefetched: [String: LocalPhotoPreviewImages] = [:]
    @State private var lastPreviewSettings: PhotoEffectsSettings?
    @State private var failed = false
    @GestureState private var comparing = false

    var body: some View {
        Group {
            if let images {
                Image(uiImage: comparing ? images.unfiltered : images.filtered).resizable().scaledToFit()
            } else if failed {
                Text(AppLocalized.resource("local_photo_preview_failed"))
                    .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
            } else { ProgressView().tint(ZTransferColors.accentBlue) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5)
            // A zero-distance drag starts competing with the horizontal
            // pager on every touch. Require a small movement after the long
            // press; the first sequence state still keeps comparison active
            // while the finger is held in place.
            .sequenced(before: DragGesture(minimumDistance: 12))
            .updating($comparing) { value, state, _ in
                switch value {
                case .first(true), .second(true, _): state = true
                default: break
                }
            })
        .task(id: PreviewRequest(item: item, settings: settings)) {
            do {
                if let previous = lastPreviewSettings,
                   previous.watermark.text != settings.watermark.text,
                   previous.watermark.withoutText() == settings.watermark.withoutText() {
                    // Match Android's 140 ms text-only preview debounce. A
                    // fast typing sequence cancels this task before any
                    // expensive filter/frame render starts.
                    try await Task.sleep(for: .milliseconds(140))
                }
                lastPreviewSettings = settings
                // A changed wheel selection starts a new render. Clear the
                // previous image immediately so a stale frame/filter cannot
                // look like the setting had no effect while rendering.
                images = nil
                failed = false
                let image: UIImage
                if let source { image = source }
                else {
                    let decoded = try await LocalPhotoOutput.decodePreview(item: item)
                    image = decoded.image
                    metadata = decoded.metadata
                    try Task.checkCancellation()
                    source = image
                }
                let filterKey = settings.photoFilterEnabled ? settings.selectedFilter : nil
                let settingsKey = String(
                    data: (try? JSONEncoder().encode(settings)) ?? Data(),
                    encoding: .utf8,
                ) ?? ""
                let preparedSource: UIImage?
                if let filterKey {
                    if filteredSourceKey == filterKey, let filteredSource {
                        preparedSource = filteredSource
                    } else {
                        let rendered = try await LocalPhotoOutput.filteredSource(image: image, selection: filterKey)
                        try Task.checkCancellation()
                        filteredSource = rendered
                        filteredSourceKey = filterKey
                        preparedSource = rendered
                    }
                } else {
                    filteredSource = nil
                    filteredSourceKey = nil
                    preparedSource = nil
                }
                let next: LocalPhotoPreviewImages
                if let cached = prefetched.removeValue(forKey: settingsKey) {
                    next = cached
                } else {
                    next = try await LocalPhotoOutput.preview(image: image, settings: settings,
                                                              metadata: metadata, filteredSource: preparedSource)
                }
                try Task.checkCancellation()
                images = next
                failed = false
                if settings.photoFilterEnabled {
                    // Android renders the selected effect first and only
                    // prepares the long-press comparison after a short idle
                    // window. Do the same so the first frame is interactive
                    // without waiting for a second full composition.
                    try await Task.sleep(for: .milliseconds(140))
                    let comparison = try await LocalPhotoOutput.unfilteredPreview(
                        image: image, settings: settings, metadata: metadata,
                    )
                    try Task.checkCancellation()
                    images = LocalPhotoPreviewImages(filtered: next.filtered, unfiltered: comparison)
                }
                if settings.photoFilterEnabled {
                    for selection in nextPhotoFilterSelections(for: settings) {
                        guard !Task.isCancelled else { return }
                        let nextSettings: PhotoEffectsSettings = {
                            var value = settings
                            value.photoFilterEnabled = true
                            value.selectedFilter = selection
                            return value
                        }()
                        let key = String(
                            data: (try? JSONEncoder().encode(nextSettings)) ?? Data(),
                            encoding: .utf8,
                        ) ?? ""
                        guard prefetched[key] == nil else { continue }
                        let nextFiltered = try await LocalPhotoOutput.filteredSource(
                            image: image, selection: selection,
                        )
                        let preview = try await LocalPhotoOutput.preview(
                            image: image, settings: nextSettings, metadata: metadata,
                            filteredSource: nextFiltered,
                        )
                        guard !Task.isCancelled else { return }
                        prefetched[key] = preview
                        if prefetched.count > 2, let oldest = prefetched.keys.first {
                            prefetched.removeValue(forKey: oldest)
                        }
                    }
                }
            } catch is CancellationError {} catch { failed = true }
        }
    }
}

private extension PhotoFrameWatermark {
    func withoutText() -> Self {
        var copy = self
        copy.text = ""
        return copy
    }
}

private struct PreviewRequest: Equatable {
    let item: PhotosPickerItem
    let settings: PhotoEffectsSettings
}

private struct WorkbenchGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ZTransferColors.secondaryText.opacity(0.15)))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(ZTransferMotion.standard, value: configuration.isPressed)
    }
}
