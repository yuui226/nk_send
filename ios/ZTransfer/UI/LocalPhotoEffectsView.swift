import PhotosUI
import SwiftUI

/// Event-time preview bounds, kept without rebuilding the image pipeline.
@MainActor
final class PhotoEffectsGeometrySnapshot {
    var previewAnchor: CGRect = .zero
}

/// Android LocalPhotoEffectsPage: fixed 4:3 pager, batch action, inline editors.
/// The picked list is the batch selection; there is no second selection grid.
struct LocalPhotoEffectsView: View {
    @ObservedObject private var entitlements = PremiumEntitlementStore.shared
    let onNavigateUp: () -> Void
    @StateObject private var effectsStore = PhotoEffectsStore(scope: .localPhotos)
    @StateObject private var batch = LocalPhotoBatchViewModel()
    @StateObject private var photoLUTLifetime = PhotoLUTEditorLifetime(role: .local)
    private var photoLUTEditor: PhotoLUTEditorState { photoLUTLifetime.editor }
    private var photoLUTStore: PhotoLUTStore { photoLUTEditor.store }
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var watermarkPickerItems: [PhotosPickerItem] = []
    @State private var previewPage = 0
    @State private var showingPicker = false
    @State private var showingHelp = false
    @State private var showingModuleMenu = false
    @AppStorage("local_photo_effects_help_viewed") private var localPhotoEffectsHelpViewed = false
    @State private var showingWatermarkPicker = false
    @State private var filterChooser = PhotoFilterChooserState()
    @State private var effectsHint: PhotoEffectsHint?
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
                                       imageImporting: effectsStore.watermarkImageImporting,
                                       photoLUTEditor: photoLUTEditor,
                                       filterChooser: $filterChooser,
                                       onFavoriteImageMissing: { effectsHint = .init(resource: "photo_effect_favorite_image_missing") })
                .padding(.top, 10).padding(.bottom, 18)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
            .photoEffectsBackgroundFocusDismiss {
                if watermarkTextFocused { watermarkTextFocused = false }
            }
        }
        .coordinateSpace(name: "local-effects-page")
        // WorkspacePagingController owns the complete nested drag and Android's
        // 30% / quick-fling settlement. A second 70pt release handler bypassed
        // that decision and could return even when the native pager cancelled.
        .background(ZTransferColors.background.ignoresSafeArea())
        .modifier(PhotoEffectModuleMenuOverlay(isPresented: $showingModuleMenu,
            draft: effectsBinding, lutStore: photoLUTStore, isPro: entitlements.access.isPro))
        .overlayPreferenceValue(TipPopupAnchorPreferenceKey.self) { anchors in
            ZStack(alignment: .topLeading) {
                PhotoLUTChooserPresentation(editor: photoLUTEditor, draft: effectsBinding)
                AndroidDialogPresentation(isPresented: filterChooser.isPresented) {
                    PhotoFilterChooserOverlay(draft: effectsBinding, state: $filterChooser,
                        onFilterSelected: { photoLUTEditor.cancelPending() })
                }
                TipPopupLayer(isPresented: showingHelp) {
                    if let anchor = anchors[.localEffects] {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showingHelp = false }
                            .gesture(DragGesture(minimumDistance: 10).onChanged { _ in })
                            .zIndex(1)
                        TipGuideBubble(anchor: anchor, titleKey: "photo_effects_info_title",
                            sections: TipGuides.effects(local: true), close: { showingHelp = false })
                        .zIndex(2)
                    }
                }
                .zIndex(1)
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
        .onReceive(photoLUTEditor.$notice.dropFirst()) { notice in
            if let notice { effectsHint = .init(resource: notice.resource) }
        }
        .onChange(of: watermarkPickerItems) { items in
            guard let item = items.last,
                  let generation = effectsStore.beginWatermarkImageImport() else { return }
            Task { @MainActor in
                let hash = await importPhotoPickerWatermarkImage(item)
                let accepted = effectsStore.finishWatermarkImageImport(generation: generation, hash: hash)
                watermarkPickerItems = []
                guard accepted else { return }
                if hash == nil || effectsStore.settings.watermark.imageHash != hash {
                    effectsHint = .init(resource: "photo_frame_image_import_failed")
                }
            }
        }
    }

    private var batchHasFailure: Bool {
        !batch.state.progress.failures.isEmpty
    }

    private var batchFailureText: String {
        let failed = max(batch.state.progress.failed, batch.state.progress.failures.count)
        return AppLocalized.formattedResource("local_photo_batch_failure_detail", ["%1$d": "\(failed)"])
    }

    @ViewBuilder private var batchFailureView: some View {
        if batchHasFailure {
            VStack(alignment: .leading, spacing: 6) {
                Text(batchFailureText)
                    .foregroundStyle(ZTransferColors.secondaryText)
                ForEach(batch.state.progress.failures, id: \.number) { failure in
                    Text(localPhotoFailureText(failure))
                        .foregroundStyle(Color.red)
                }
            }
            .font(.system(size: 12))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }

    private var effectsBinding: Binding<PhotoEffectsSettings> {
        Binding(get: { effectsStore.settings }, set: { effectsStore.updateFromEditor($0) })
    }

    private var previewSettings: PhotoEffectsSettings {
        var value = effectsStore.settings
        value.metadata = value.metadataByPreset[value.photoFramePreset.rawValue] ?? value.metadata
        return effectivePhotoEffectsSettings(value, isPro: entitlements.access.isPro)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onNavigateUp) {
                Image(systemName: "chevron.up").font(.system(size: 19, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 19))
            // UIPageViewController's rotated vertical pager can retain the
            // Button's internal tap recognizer after an interactive page
            // transition. Own the physical tap at the toolbar level and send
            // it through the exact same callback used by the downward return
            // gesture. The pager's destination guard makes a second delivery
            // from keyboard/accessibility activation harmless.
            .highPriorityGesture(TapGesture().onEnded { onNavigateUp() })
            Text(AppLocalized.resource("local_photo_effects_entry")).font(.system(size: 16, weight: .bold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            PhotoEffectModuleMenuButton(isPresented: $showingModuleMenu)
            TipLightbulbButton(
                attention: !localPhotoEffectsHelpViewed, size: 38,
                accessibilityLabel: AppLocalized.resource("photo_effects_info_title")
            ) {
                localPhotoEffectsHelpViewed = true
                showingHelp = true
            }
            .tipPopupAnchor(.localEffects)
        }
        .foregroundStyle(ZTransferColors.primaryText)
    }

    private var preview: some View {
        Group {
            if batch.state.photos.isEmpty {
                Button { openPhotoPicker() } label: {
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
                        GeometryReader { proxy in
                            // Android beyondViewportPageCount=0: decode pages
                            // intersecting the viewport, including the incoming
                            // page during a swipe, without retaining idle neighbours.
                            let frame = proxy.frame(in: .named("localPreviewPager"))
                            if localPreviewPageIsVisible(frame: frame, viewportWidth: proxy.size.width) {
                                LocalEffectPreview(
                                    item: batch.state.photos[index],
                                    settings: previewSettings,
                                    allowsFilterPrefetch: index == previewPage && !batch.state.generating,
                                    onWillOpen: { watermarkTextFocused = false }
                                )
                            } else { Color.clear }
                        }.tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .coordinateSpace(name: "localPreviewPager")
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
        HStack(spacing: 10) {
            if !batch.state.photos.isEmpty {
                Button { openPhotoPicker() } label: {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 23))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 20))
                .disabled(batch.state.generating)
                .accessibilityLabel(AppLocalized.formattedResource("local_photo_reselect", ["%1$d": "\(batch.state.photos.count)"]))
                .transition(.asymmetric(
                    insertion: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)),
                    removal: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.14))))
            }
            Button {
                if batch.state.photos.isEmpty { openPhotoPicker() }
                else {
                    watermarkTextFocused = false
                    batch.generate(settings: previewSettings)
                }
            } label: {
                LocalPhotoBatchLabel(
                    state: batch.state,
                    pageLabel: batch.state.photos.isEmpty ? nil : "\(previewPage + 1) / \(batch.state.photos.count)"
                )
                    .frame(maxWidth: .infinity).frame(height: 50).clipped()
            }
            .buttonStyle(ZTransferGlassButtonStyle(
                cornerRadius: 20,
                active: batch.state.generating ||
                    (!batch.state.photos.isEmpty && effectsStore.settings.hasEffect),
                activeColor: ZTransferColors.accentBlue
            ))
            .disabled(batch.state.phase != .ready || (!batch.state.photos.isEmpty && !effectsStore.settings.hasEffect))
        }
        .animation(ZTransferMotion.inlineExpansion, value: batch.state.photos.isEmpty)
    }

    private func openPhotoPicker() {
        // Android launches a fresh ACTION_PICK for both choose and replace;
        // do not feed the previous PhotosPicker selection back as preselection.
        pickerItems = []
        showingPicker = true
    }
}

/// Android's selectable diagnostic block, including the original photo number.
func localPhotoFailureText(_ failure: LocalPhotoFailure) -> String {
    let stage = ["save", "render"].contains(failure.stage) ? failure.stage : "prepare"
    let kind = ["memory", "permission", "missing", "space"].contains(failure.kind) ? failure.kind : "unknown"
    return AppLocalized.formattedResource("local_photo_error_item", [
        "%1$d": String(failure.number), "%2$s": AppLocalized.resource("local_photo_error_\(stage)")
    ]) + "\n" + AppLocalized.resource("local_photo_error_\(kind)") + "\n" + failure.detail
}

private struct LocalPhotoBatchLabel: View {
    let state: LocalPhotoBatchState<PhotosPickerItem>
    let pageLabel: String?
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
                        Text(" / \(state.progress.total)").fontWeight(.bold).monospacedDigit()
                    }
                } else {
                    if let pageLabel, !state.photos.isEmpty, state.phase == .ready {
                        Text(pageLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ZTransferColors.secondaryText)
                            .monospacedDigit()
                    }
                    Text(text)
                }
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
                : AppLocalized.resource("local_photo_generate")
        }
    }
}

/// Mirrors Android ExpandedEffectsPreview and its identity-gated comparison provider.
struct PhotoEffectsExpandedPreviewSnapshot {
    let image: UIImage
    let initialComparison: UIImage?
    let anchor: CGRect

    func comparison(current: LocalPhotoPreviewImages?) -> UIImage? {
        comparison(image: current?.filtered, unfiltered: current?.unfiltered)
    }

    func comparison(image currentImage: UIImage?, unfiltered: UIImage?) -> UIImage? {
        currentImage === image ? (unfiltered ?? initialComparison) : initialComparison
    }
}

private struct LocalEffectPreview: View {
    let item: PhotosPickerItem
    let settings: PhotoEffectsSettings
    let allowsFilterPrefetch: Bool
    let onWillOpen: () -> Void
    @State private var expandedSnapshot: PhotoEffectsExpandedPreviewSnapshot?
    @State private var expanded = false
    @State private var geometry = PhotoEffectsGeometrySnapshot()
    @State private var sourceName = ""
    @State private var source: UIImage?
    @State private var metadata: PhotoFrameMetadata?
    @State private var images: LocalPhotoPreviewImages?
    @StateObject private var previewCache = LocalPhotoPreviewCache()
    @State private var lastPreviewSettings: PhotoEffectsSettings?
    @State private var failed = false
    @State private var renderedCanvasKey = ""
    @State private var previewRestoreRevision = 0
    @State private var comparing = false

    private static func differsOnlyInWatermarkText(
        _ previous: PhotoEffectsSettings, _ current: PhotoEffectsSettings
    ) -> Bool {
        guard previous.watermark.text != current.watermark.text else { return false }
        var lhs = previous
        var rhs = current
        lhs.watermark.text = ""
        rhs.watermark.text = ""
        return lhs == rhs
    }

    private static func comparisonPreview(
        image: UIImage, settings: PhotoEffectsSettings, metadata: PhotoFrameMetadata?
    ) async -> UIImage? {
        do {
            try await Task.sleep(for: .milliseconds(500))
            return try await LocalPhotoOutput.unfilteredPreview(
                image: image, settings: settings, metadata: metadata
            )
        } catch { return nil }
    }

    var body: some View {
        Group {
            if let images {
                PhotoEffectsAnimatedImage(
                    frame: .init(
                        image: images.filtered,
                        comparison: images.unfiltered,
                        canvasKey: renderedCanvasKey
                    ),
                    requestedCanvasKey: photoEffectsPreviewCanvasKey(settings),
                    showComparison: comparing,
                    restoreRevision: previewRestoreRevision, failed: failed
                )
                .overlay(alignment: .bottom) {
                    if failed { previewUnavailableBadge }
                }
            } else if failed, let source {
                Image(uiImage: source)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .overlay(alignment: .bottom) { previewUnavailableBadge }
            } else if failed {
                Text(AppLocalized.resource("local_photo_preview_failed"))
                    .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
            } else { ProgressView().tint(ZTransferColors.accentBlue) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { geometry.previewAnchor = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { geometry.previewAnchor = $0 }
        })
        .overlay { PhotoEffectsImageInput(comparing: $comparing, comparisonEnabled: images?.unfiltered != nil, onTap: { _ in
            guard let images, !comparing else { return }
            onWillOpen()
            expandedSnapshot = PhotoEffectsExpandedPreviewSnapshot(image: images.filtered,
                initialComparison: images.unfiltered, anchor: geometry.previewAnchor)
            expanded = true
        }) }
        .fullScreenCover(isPresented: $expanded, onDismiss: {
            expandedSnapshot = nil
        }) {
            if let expandedSnapshot {
                PhotoEffectsExpandedPreview(
                    image: expandedSnapshot.image,
                    comparison: expandedSnapshot.comparison(current: images),
                    initialAnchor: expandedSnapshot.anchor
                ) { expanded = false }
            }
        }
        .task(id: PreviewRequest(
            item: item, settings: photoEffectsPreviewPixelSettings(settings)
        )) {
            do {
                let pixelSettings = photoEffectsPreviewPixelSettings(settings)
                if let previous = lastPreviewSettings,
                   Self.differsOnlyInWatermarkText(previous, pixelSettings) {
                    // Match Android's 140 ms text-only preview debounce. A
                    // fast typing sequence cancels this task before any
                    // expensive filter/frame render starts.
                    try await Task.sleep(for: .milliseconds(140))
                }
                lastPreviewSettings = pixelSettings
                failed = false
                let image: UIImage
                if let source { image = source }
                else {
                    let decoded = try await LocalPhotoOutput.decodePreview(item: item)
                    image = decoded.image
                    metadata = decoded.metadata
                    sourceName = decoded.sourceName
                    try Task.checkCancellation()
                    source = image
                }
                await previewCache.configure(image: image, settings: settings, metadata: metadata,
                                             prefetchEnabled: allowsFilterPrefetch, sourceName: sourceName)
                let next = try await previewCache.render(image: image, settings: settings, metadata: metadata)
                try Task.checkCancellation()
                renderedCanvasKey = photoEffectsPreviewCanvasKey(settings)
                images = next
                failed = false
                if settings.photoFilterEnabled || settings.photoGrain.isEnabled {
                    // The comparison belongs to each composed page. Filter
                    // prefetch is a separate task below because Android only
                    // warms the currently settled page while not generating.
                    if let comparison = await Self.comparisonPreview(
                        image: image, settings: settings, metadata: metadata
                    ), !Task.isCancelled {
                        images = LocalPhotoPreviewImages(
                            filtered: next.filtered, unfiltered: comparison
                        )
                    }
                }
            } catch is CancellationError {} catch {
                failed = true
                if images != nil { previewRestoreRevision &+= 1 }
            }
        }
        .task(id: LocalPreviewPrefetchRequest(
            item: item,
            settings: settings,
            enabled: allowsFilterPrefetch && images != nil && source != nil
        )) {
            guard images != nil, let source else { return }
            await previewCache.configure(image: source, settings: settings, metadata: metadata,
                                         prefetchEnabled: allowsFilterPrefetch, sourceName: sourceName)
            guard allowsFilterPrefetch, settings.photoFilterEnabled, !Task.isCancelled else { return }
            do {
                if settings.photoGrain.isEnabled && !nextPhotoFilterSelections(for: settings).isEmpty {
                    try await Task.sleep(for: .milliseconds(600))
                }
                for selection in nextPhotoFilterSelections(for: settings) {
                    try Task.checkCancellation()
                    var next = settings
                    next.photoFilterEnabled = true
                    next.selectedFilter = selection
                    _ = try await previewCache.render(image: source, settings: next, metadata: metadata)
                }
            } catch { /* Cancelled or obsolete prefetch never changes the visible frame. */ }
        }
        .onDisappear { previewCache.close() }
    }

    private var previewUnavailableBadge: some View {
        Text(AppLocalized.resource("photo_frame_preview_unavailable"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ZTransferColors.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 6)
    }
}

private struct PreviewRequest: Equatable {
    let item: PhotosPickerItem
    let settings: PhotoEffectsSettings
}

private struct LocalPreviewPrefetchRequest: Equatable {
    let item: PhotosPickerItem
    let settings: PhotoEffectsSettings
    let enabled: Bool
}

/// Half-open viewport intersection excludes pages resting exactly one width away.
func localPreviewPageIsVisible(frame: CGRect, viewportWidth: CGFloat) -> Bool {
    viewportWidth > 0 && frame.maxX > 0 && frame.minX < viewportWidth
}
